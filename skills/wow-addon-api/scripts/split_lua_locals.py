import argparse
from collections import Counter
from pathlib import Path
import sys

from align_lua import align_source, parse, walk


ROOT = Path(__file__).resolve().parents[3]


# Yield local declarations containing multiple names together with their initializer expressions.
def declarations(source):
    for node in walk(parse(source)):
        if node.type != 'variable_declaration':
            continue
        assigned = next((child for child in node.named_children if child.type == 'assignment_statement'), node)
        variables = next((child for child in assigned.named_children if child.type == 'variable_list'), None)
        if variables is None:
            continue
        names = [child for child in variables.named_children if child.type == 'identifier']
        if len(names) < 2:
            continue
        values = next((child for child in assigned.named_children if child.type == 'expression_list'), None)
        yield node, names, values


# Locate declarations that place more than one local binding on the same line.
def violations(source):
    found = []
    for node, names, values in declarations(source):
        previous_line = None
        for name in names:
            line_number = source.count(b'\n', 0, name.start_byte) + 1
            if line_number == previous_line:
                found.append(line_number)
                break
            previous_line = line_number
    return found


# Collect meaningful token counts and ordered comments for declaration-rewrite equivalence checks.
def contents(source):
    meaningful = []
    comments = []

    # Collect tokens and comments while excluding punctuation that declaration splitting may change.
    def visit(node):
        if node.type in ('string', 'number', 'comment') or not node.children:
            token = source[node.start_byte:node.end_byte]
            if token not in (b'local', b'=', b','):
                meaningful.append((node.type, token))
            if node.type == 'comment':
                comments.append(token)
        else:
            for child in node.children:
                visit(child)

    visit(parse(source))
    return Counter(meaningful), comments


# Collect identifiers used by an initializer, excluding property names and named table keys.
def initializer_references(source, expression):
    references = set()
    for node in walk(expression):
        if node.type != 'identifier':
            continue
        parent = node.parent
        if parent.type in ('dot_index_expression', 'method_index_expression') and parent.named_children[-1] == node:
            continue
        if parent.type == 'field' and parent.child_by_field_name('name') == node:
            continue
        references.add(source[node.start_byte:node.end_byte])
    return references


# Check whether independent local declarations preserve initializer scope and return-value semantics.
def can_split(source, node, names, values):
    if any(child.type == 'comment' for child in walk(node)):
        return False
    name_texts = [source[name.start_byte:name.end_byte] for name in names]
    if len(name_texts) != len(set(name_texts)):
        return False
    if values is None:
        return True
    expressions = values.named_children
    if len(expressions) != len(names):
        return False
    declared = set()
    for name_text, expression in zip(name_texts, expressions):
        if initializer_references(source, expression) & declared:
            return False
        declared.add(name_text)
    return True


# Render independent local declarations while preserving each original initializer expression.
def separate_declarations(source, node, names, values, indentation, newline):
    if values is None:
        return (newline + indentation).join(b'local ' + source[name.start_byte:name.end_byte] for name in names)
    statements = []
    for name, expression in zip(names, values.named_children):
        statements.append(b'local ' + source[name.start_byte:name.end_byte] + b' = '
                          + source[expression.start_byte:expression.end_byte])
    return (newline + indentation).join(statements)


# Put shared declaration names on separate lines without splitting their initializer.
def shared_declaration(source, node, names, newline, indentation):
    replacement = source[node.start_byte:node.end_byte]
    for name in reversed(names[1:]):
        padding_start = name.start_byte
        while padding_start > node.start_byte and source[padding_start - 1] in (32, 9, 10, 13):
            padding_start -= 1
        relative_start = padding_start - node.start_byte
        relative_end = name.start_byte - node.start_byte
        replacement = replacement[:relative_start] + newline + indentation + b'    ' + replacement[relative_end:]
    return replacement


# Rewrite multi-name locals safely, checking token preservation and optional semantic equivalence.
def split_source(source, equivalent=None):
    original = source
    newline = b'\r\n' if b'\r\n' in source else b'\n'
    while True:
        candidates = []
        for node, names, values in declarations(source):
            line_numbers = [source.count(b'\n', 0, name.start_byte) for name in names]
            if len(line_numbers) != len(set(line_numbers)):
                candidates.append((node, names, values))
        if not candidates:
            break
        node, names, values = candidates[-1]
        line_start = source.rfind(b'\n', 0, node.start_byte) + 1
        line_prefix = source[line_start:node.start_byte]
        indentation = line_prefix[:len(line_prefix) - len(line_prefix.lstrip(b' \t'))]
        replacement = None
        if can_split(source, node, names, values):
            replacement = separate_declarations(source, node, names, values, indentation, newline)
            proposed = source[:node.start_byte] + replacement + source[node.end_byte:]
            if equivalent is not None and not equivalent(source, proposed):
                replacement = None
        if replacement is None:
            replacement = shared_declaration(source, node, names, newline, indentation)
        proposed = source[:node.start_byte] + replacement + source[node.end_byte:]
        if equivalent is not None and not equivalent(source, proposed):
            raise ValueError('Declaration layout changed executable Lua behavior')
        source = proposed
    if contents(original) != contents(source):
        raise ValueError('Declaration layout changed identifiers, initializers, or comments')
    if violations(source):
        raise ValueError('Multiple local bindings remain on the same line')
    return source


# Verify safe splitting, shared initializers, scope dependencies, comment retention, and newline handling.
def self_test():
    independent = b'local seen, good, allSeen, allGood = {}, {}, 0, 0\n'
    expected = b'local seen = {}\nlocal good = {}\nlocal allSeen = 0\nlocal allGood = 0\n'
    assert split_source(independent) == expected
    assert split_source(b'local first, second\n') == b'local first\nlocal second\n'
    shared = b'local class, classFile = UnitClass(unitToken)\n'
    assert split_source(shared) == b'local class,\n    classFile = UnitClass(unitToken)\n'
    scoped = b'local outerValue, copiedValue = 2, outerValue\n'
    assert split_source(scoped) == b'local outerValue,\n    copiedValue = 2, outerValue\n'
    trailing_comment = b'local first, second = {}, {} -- preserve\n'
    assert split_source(trailing_comment).endswith(b'-- preserve\n')
    internal_comment = b'local first, -- preserve\n    second = {}, {}\n'
    assert split_source(internal_comment) == internal_comment
    namespace = b'local ADDON, NS = ...\r\n'
    assert split_source(namespace) == b'local ADDON,\r\n    NS = ...\r\n'
    duplicates = b'local first, first = 1, 2\n'
    assert split_source(duplicates) == b'local first,\n    first = 1, 2\n'
    extra_values = b'local first, second = 1, 2, SideEffect()\n'
    assert split_source(extra_values) == b'local first,\n    second = 1, 2, SideEffect()\n'
    samples = [independent, shared, scoped, trailing_comment, internal_comment, namespace, duplicates, extra_values]
    for sample in samples:
        formatted = split_source(sample)
        assert not violations(formatted)
        assert split_source(formatted) == formatted
    print('PASS: independent locals, multiple returns, outer scope, comments, duplicates, side effects, line endings, and idempotence')


# Check or rewrite local declarations in selected Lua files, or run the splitter self-test.
def main():
    argument_parser = argparse.ArgumentParser(description='Put each Lua local binding on its own declaration line.')
    argument_parser.add_argument('paths', nargs='*', type=Path)
    argument_parser.add_argument('--check', action='store_true')
    argument_parser.add_argument('--self-test', action='store_true')
    arguments = argument_parser.parse_args()
    if arguments.self_test:
        self_test()
        return 0
    files = set()
    for path in arguments.paths or [ROOT]:
        candidates = path.rglob('*.lua') if path.is_dir() else [path]
        files.update(candidate.resolve() for candidate in candidates if '.git' not in candidate.parts)
    outputs = {}
    for path in sorted(files):
        source = path.read_bytes()
        if arguments.check:
            for line_number in violations(source):
                print(f'{path.relative_to(ROOT)}:{line_number}: put each local binding on its own line')
                outputs[path] = None
        else:
            formatted = align_source(split_source(source))
            if formatted != source:
                outputs[path] = formatted
    if not arguments.check:
        for path, formatted in outputs.items():
            path.write_bytes(formatted)
            print('Reformatted local declarations: ' + str(path.relative_to(ROOT)))
    print(f'{len(files)} Lua files checked; {len(outputs)} ' + ('need local-layout changes' if arguments.check else 'updated'))
    return 1 if arguments.check and outputs else 0


if __name__ == '__main__':
    sys.exit(main())