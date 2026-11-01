"""Order module declarations in preprocessed simulation copies for ModelSim 10.5b."""
import re
import sys
from pathlib import Path


def split_fields(text):
    depth = 0
    start = 0
    fields = []
    for i, char in enumerate(text):
        if char in '([{':
            depth += 1
        elif char in ')]}':
            depth -= 1
        elif char == ',' and depth == 0:
            fields.append(text[start:i])
            start = i + 1
    return fields + [text[start:]]


source = Path(sys.argv[1]).read_text()
source = re.sub(r'(?m)^`line 1 "[^"\n]+\.(?:sv|v)" 0\s*$', '`default_nettype wire', source)
source = re.sub(r'(?m)^`line[^\n]*', '', source)
# Keep offsets while masking comments and strings for scope tracking.
masked = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"',
                lambda m: re.sub(r'[^\n]', ' ', m[0]), source)
tokens = list(re.finditer(r'\b\w+\b|[();]', masked))
edits = []
header = None
inside = False
depth = 0
parens = 0
skip = 0
declarations = []
for token in tokens:
    word = token[0]
    pos = token.start()
    if pos < skip:
        continue
    if word == 'module':
        inside = True
        header = None
        parens = 0
        declarations = []
    elif not inside:
        continue
    elif header is None:
        if word == '(':
            parens += 1
        elif word == ')':
            parens -= 1
        elif word == ';' and parens == 0:
            header = token.end()
            depth = 0
    elif word == 'endmodule':
        ordered = sorted(declarations, key=lambda d: not d.startswith('localparam'))
        edits.append((header, header, '\n' + '\n'.join(ordered) + '\n'))
        inside = False
    elif word in ('begin', 'function', 'task', 'generate', 'fork'):
        depth += 1
    elif word in ('end', 'endfunction', 'endtask', 'endgenerate', 'join', 'join_any', 'join_none'):
        depth -= 1
    elif depth == 0 and word in ('input', 'output', 'inout', 'parameter'):
        skip = masked.index(';', token.end()) + 1
        header = skip
    elif depth == 0 and word in ('reg', 'wire', 'localparam', 'integer', 'genvar'):
        end = masked.index(';', token.end()) + 1
        declaration = source[pos:end]
        replacement = ''
        if word == 'wire':
            fields = split_fields(declaration[4:-1])
            bare = []
            for field in fields:
                parts = field.split('=', 1)
                bare.append(parts[0])
                if len(parts) == 2:
                    name = re.search(r'(\w+)\s*$', parts[0])
                    if name is None:
                        raise ValueError('Unsupported net declaration: ' + declaration)
                    replacement += 'assign ' + name[1] + ' =' + parts[1] + ';\n'
            declaration = 'wire' + ','.join(bare) + ';'
        declarations.append(declaration)
        edits.append((pos, end, replacement))
        skip = end
for start, end, replacement in sorted(edits, reverse=True):
    source = source[:start] + replacement + source[end:]
Path(sys.argv[2]).write_text(source)
