import argparse
from pathlib import Path
import sys

from align_lua import parse, walk


ROOT = Path(__file__).resolve().parents[3]  # Addon root used when no source paths are passed.
PUBLIC_NAMES = {'NS', 'UI', 'ADDON'}  # Established namespace names exempt from the opaque-name rule.
OPAQUE_NAMES = {  # Short aliases rejected even when their character count exceeds the generic limit.
    'src', 'dst', 'arr', 'opts', 'arg1', 'arg2', 'arg3', 'arg4', 'arg5', 'arg6',
    'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'minL', 'maxL', 'tmp', 'temp', 'foo', 'bar',
}


# Collect local declarations, parameters, and loop bindings with their source byte offsets.
# @param source Lua source bytes to audit.
def bindings(source):
    declarations = {}

    # Record an identifier binding once, keyed by its starting byte offset.
    # @param identifier Parsed syntax node for the binding, if present.
    def remember(identifier):
        if identifier is not None and identifier.type == 'identifier':
            declarations[identifier.start_byte] = source[identifier.start_byte:identifier.end_byte].decode('utf-8')

    for node in walk(parse(source)):
        if node.type == 'variable_declaration':
            declaration = next((child for child in node.named_children if child.type == 'assignment_statement'), node)
            variables = next((child for child in declaration.named_children if child.type == 'variable_list'), None)
            if variables is not None:
                for identifier in variables.named_children:
                    remember(identifier)
        elif node.type == 'parameters':
            for identifier in node.named_children:
                remember(identifier)
        elif node.type == 'for_numeric_clause':
            remember(node.named_children[0])
        elif node.type == 'for_generic_clause':
            variables = next((child for child in node.named_children if child.type == 'variable_list'), None)
            if variables is not None:
                for identifier in variables.named_children:
                    remember(identifier)
        elif node.type == 'function_declaration' and any(child.type == 'local' for child in node.children):
            remember(node.child_by_field_name('name'))
    return sorted(declarations.items())


# Return line numbers and names for short or opaque bindings outside the public-name allowlist.
# @param source Lua source bytes to audit.
def violations(source):
    return [(source.count(b'\n', 0, offset) + 1, name) for offset, name in bindings(source)
            if name not in PUBLIC_NAMES and (len(name) <= 2 or name in OPAQUE_NAMES)]


# Verify that the naming audit catches opaque bindings without flagging table fields or string contents.
def self_test():
    meaningful = b'''local guildData = { r = 1, g = 2, b = 3 }
local NS, UI = namespace, interface
for memberIndex, member in ipairs(members) do
    Observe(member)
end
local function Read(memberName)
    return memberName
end
'''
    assert not violations(meaningful)
    example = b'local i, record = 1, {}\nfor k, v in pairs(record) do end\nlocal function f(_, j) return j end\n'
    assert {name for line_number, name in violations(example)} == {'i', 'k', 'v', 'f', '_', 'j'}
    assert not violations(b'local record = { i = "j", k = "u" }; return record.i\n')
    print('PASS: naming audit detects declarations, loop bindings, parameters, and local functions without flagging field keys or strings')


# Audit selected Lua files, print naming violations, and return a failing exit status when any exist.
def main():
    argument_parser = argparse.ArgumentParser(description='Reject placeholder and opaque Lua variable bindings.')
    argument_parser.add_argument('paths', nargs='*', type=Path)
    argument_parser.add_argument('--self-test', action='store_true')
    arguments = argument_parser.parse_args()
    if arguments.self_test:
        self_test()
        return 0
    files = set()
    for path in arguments.paths or [ROOT]:
        candidates = path.rglob('*.lua') if path.is_dir() else [path]
        files.update(candidate.resolve() for candidate in candidates if '.git' not in candidate.parts)
    violation_count = 0
    for path in sorted(files):
        for line_number, name in violations(path.read_bytes()):
            violation_count += 1
            print(f'{path.relative_to(ROOT)}:{line_number}: replace opaque binding {name!r} with a role-specific name')
    print(f'{len(files)} Lua files checked; {violation_count} naming violations')
    return 1 if violation_count else 0


if __name__ == '__main__':
    sys.exit(main())