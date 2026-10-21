import argparse
from bisect import bisect_right
from dataclasses import dataclass
from pathlib import Path
import sys
import tomllib

from tree_sitter import Language, Parser
import tree_sitter_lua


PARSER = Parser(Language(tree_sitter_lua.language()))  # Shared Tree-sitter parser for Lua source bytes.
ROOT = Path(__file__).resolve().parents[4]  # Addon root used as the default formatting scope.


@dataclass
class Assignment:
    """Stores source spans and alignment measurements for one Lua assignment."""

    first_line: int
    last_line: int
    indentation: bytes
    family: str
    left_end: int
    left_column: int
    equals_start: int
    equals_end: int
    equals_column: int
    after_end: int
    after_delta: int
    code_width: int


# Parse Lua bytes and reject sources containing syntax errors.
# @param source Lua source bytes to parse.
def parse(source):
    root = PARSER.parse(source).root_node
    if root.has_error:
        raise ValueError('Cannot align Lua with syntax errors')
    return root


# Yield each named syntax node in depth-first order.
# @param node Parsed tree node whose descendants should be visited.
def walk(node):
    yield node
    for child in node.named_children:
        yield from walk(child)


# Collect exact Lua token, literal, and comment bytes for formatting equivalence checks.
# @param source Lua source bytes to fingerprint.
def fingerprint(source):
    pieces = []

    # Record atomic tokens and comments while recursively traversing the parsed source.
    def visit(node):
        if node.type in ('string', 'number', 'comment') or not node.children:
            pieces.append((node.type, source[node.start_byte:node.end_byte]))
        else:
            for child in node.children:
                visit(child)

    visit(parse(source))
    return pieces


# Align consecutive assignment groups within the column limit while preserving all Lua tokens.
# @param source Lua source bytes to format.
# @param column_width Maximum code width before an alignment group is split.
def align_source(source, column_width=120):
    root = parse(source)
    line_starts = [0]
    line_starts.extend(index + 1 for index, value in enumerate(source) if value == 10)
    comments = [node for node in walk(root) if node.type == 'comment']
    comments_by_line = {}

    # Map a source byte offset to its zero-based line index.
    # @param offset Byte position within source.
    def line_number(offset):
        return bisect_right(line_starts, offset) - 1

    # Measure decoded text width with tabs expanded to four spaces.
    # @param fragment Source bytes whose display width should be measured.
    def width(fragment):
        return len(fragment.decode('utf-8').expandtabs(4))

    for comment in comments:
        comments_by_line.setdefault(line_number(comment.start_byte), []).append(comment)

    # Extract alignment offsets and widths for an eligible single-line assignment prefix.
    # @param node Parsed assignment or declaration node.
    # @param family Assignment grouping kind used to avoid mixing fields and statements.
    def assignment(node, family):
        first_line = line_number(node.start_byte)
        line_start = line_starts[first_line]
        indentation = source[line_start:node.start_byte]
        if indentation.strip(b' \t'):
            return None
        assigned = node
        if node.type == 'variable_declaration':
            assigned = next((child for child in node.named_children if child.type == 'assignment_statement'), None)
        if assigned is None:
            return None
        equals = next((child for child in assigned.children if child.type == '='), None)
        if equals is None or line_number(equals.start_byte) != first_line:
            return None
        left = source[node.start_byte:equals.start_byte].rstrip(b' \t')
        if b'\n' in left or b'\r' in left:
            return None
        left_end = node.start_byte + len(left)
        after_end = equals.end_byte
        while after_end < len(source) and source[after_end] in (32, 9):
            after_end += 1
        after_delta = 0 if source[after_end:after_end + 1] in (b'\r', b'\n') else 1 - (after_end - equals.end_byte)
        line_end = source.find(b'\n', equals.end_byte)
        if line_end < 0:
            line_end = len(source)
        code_end = min([line_end] + [comment.start_byte for comment in comments_by_line.get(first_line, [])
                                     if comment.start_byte > equals.start_byte])
        code = source[line_start:code_end].rstrip(b' \t\r')
        return Assignment(first_line, line_number(node.end_byte - 1), indentation, family,
                          left_end, width(source[line_start:left_end]), equals.start_byte,
                          equals.end_byte, width(source[line_start:equals.start_byte]),
                          after_end, after_delta, width(code))

    edits = []

    # Generate whitespace edits for an assignment group, splitting groups that exceed the column limit.
    # @param group Consecutive compatible assignments to align.
    def finish(group):
        if len(group) < 2:
            return
        target_column = max(row.left_column for row in group) + 2
        too_wide = [index for index, row in enumerate(group)
                    if row.code_width + target_column - row.equals_column + row.after_delta > column_width]
        if too_wide:
            start = 0
            for index in too_wide:
                finish(group[start:index])
                start = index + 1
            finish(group[start:])
            return
        for row in group:
            padding = b' ' * (target_column - row.left_column)
            if source[row.left_end:row.equals_start] != padding:
                edits.append((row.left_end, row.equals_start, padding))
            if source[row.after_end:row.after_end + 1] not in (b'\r', b'\n'):
                if source[row.equals_end:row.after_end] != b' ':
                    edits.append((row.equals_end, row.after_end, b' '))

    for container in walk(root):
        if container.type not in ('table_constructor', 'chunk', 'block'):
            continue
        group = []
        for child in container.named_children:
            if child.type == 'comment':
                if (group and line_number(child.start_byte) == group[-1].last_line
                        and line_number(child.end_byte - 1) == group[-1].last_line):
                    continue
                finish(group)
                group = []
                continue
            if container.type == 'table_constructor':
                row = assignment(child, 'field') if child.type == 'field' else None
            elif child.type in ('assignment_statement', 'variable_declaration'):
                row = assignment(child, child.type)
            else:
                row = None
            if row is None:
                finish(group)
                group = []
                continue
            if group and (row.first_line != group[-1].last_line + 1
                          or row.indentation != group[-1].indentation or row.family != group[-1].family):
                finish(group)
                group = []
            group.append(row)
            if row.last_line != row.first_line:
                finish(group)
                group = []
        finish(group)

    formatted = source
    boundary = len(source)
    for start, end, replacement in sorted(edits, reverse=True):
        if end > boundary or source[start:end].strip(b' \t'):
            raise ValueError('Alignment attempted to change non-whitespace source')
        formatted = formatted[:start] + replacement + formatted[end:]
        boundary = start
    if fingerprint(source) != fingerprint(formatted):
        raise ValueError('Alignment changed Lua tokens, literals, or comments')
    return formatted


# Check alignment, newline preservation, idempotence, and safe handling of literals and comments.
def self_test():
    before = b'local ms = {\n    queries = {},\n    index = 0,\n    awaiting = false,\n}\n'
    expected = b'local ms = {\n    queries   = {},\n    index     = 0,\n    awaiting  = false,\n}\n'
    for newline in (b'\n', b'\r\n'):
        source = before.replace(b'\n', newline)
        formatted = align_source(source)
        assert formatted == expected.replace(b'\n', newline)
        assert align_source(formatted) == formatted

    compact = b'local state = { short = "a = b", longer = "==" }\n'
    assert align_source(compact) == compact
    separate = b'local short = 1\n\nlocal longer = 2\n-- separator\nlocal longest = 3\n'
    assert align_source(separate) == separate
    branches = b'if enabled then\n    value.short = 1\nelse\n    value.longer = 2\nend\n'
    assert align_source(branches) == branches
    source = b'''local state = {
    ["a"] = "==", -- literal = value
    ["longer"] = "a = b",
    nested = {
        short = 1,
        longer = 2,
    },
    last = 3,
}
local first = 1
local longer = 2
state.short = 3
state.longer = 4
'''
    formatted = align_source(source)
    assert b'    ["a"]       = "==", -- literal = value' in formatted
    assert b'        short   = 1' in formatted
    assert b'        longer  = 2' in formatted
    assert b'local first   = 1' in formatted
    assert b'local longer  = 2' in formatted
    assert b'state.short   = 3' in formatted
    assert b'state.longer  = 4' in formatted
    assert fingerprint(source) == fingerprint(formatted)
    assert align_source(formatted) == formatted
    long_value = b'local data = {\n    short = "' + b'x' * 115 + b'",\n    longer = 2,\n}\n'
    assert align_source(long_value) == long_value
    print('PASS: fields, assignments, scopes, inline tables, literals, comments, width, line endings, and idempotence')


# Read formatting settings and check or rewrite selected Lua files, or run the alignment self-test.
def main():
    argument_parser = argparse.ArgumentParser(description='Align Lua assignment groups without changing tokens.')
    argument_parser.add_argument('paths', nargs='*', type=Path)
    argument_parser.add_argument('--check', action='store_true')
    argument_parser.add_argument('--self-test', action='store_true')
    argument_parser.add_argument('--column-width', type=int)
    arguments = argument_parser.parse_args()
    if arguments.self_test:
        self_test()
        return 0
    settings = tomllib.loads((ROOT / '.stylua.toml').read_text(encoding='utf-8'))
    column_width = arguments.column_width or settings.get('column_width', 120)
    paths = set()
    for path in arguments.paths or [ROOT]:
        candidates = path.rglob('*.lua') if path.is_dir() else [path]
        paths.update(candidate.resolve() for candidate in candidates if '.git' not in candidate.parts)
    outputs = {}
    for path in sorted(paths):
        source = path.read_bytes()
        formatted = align_source(source, column_width)
        if formatted != source:
            outputs[path] = formatted
    for path, formatted in outputs.items():
        if not arguments.check:
            path.write_bytes(formatted)
        print(('Would align ' if arguments.check else 'Aligned ') + str(path.relative_to(ROOT)))
    print(f'{len(paths)} Lua files checked; {len(outputs)} ' + ('need alignment' if arguments.check else 'aligned'))
    return 1 if arguments.check and outputs else 0


if __name__ == '__main__':
    sys.exit(main())