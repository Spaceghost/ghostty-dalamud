"""Every imgui.Pop* must be covered by the Push* calls in the same function.

Dalamud ships an ImGui whose PopStyleColor/PopStyleVar do not check the stack
depth: popping more than was pushed reads an empty stack and writes
Style.Colors (or Style vars) at a junk index. That is not a wrong colour, it is
a stray write inside the game process. /ask shipped with PopStyleColor(13)
against twelve pushes and took the game down on the first frame it drew.

A function may pop on several mutually exclusive paths -- the usual shape is
`if not imgui.Begin(...) then Pop(3) return end ... Pop(3)` -- so the counts are
not required to sum to the pushes. What must hold is that no single pop is
deeper than the function ever pushed.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

FUNC = re.compile(r'^\s*(?:local\s+|global\s+)?function\s+([A-Za-z_0-9.:]+)')
END = re.compile(r'^end\s*$')
PUSH = re.compile(r'imgui\.Push(StyleColor|StyleVar)\w*\(')
POP = re.compile(r'imgui\.Pop(StyleColor|StyleVar)\((\d+)\)')


def functions(path):
    """Yield (name, line_number, body) for each top-level function in a file."""
    lines = path.read_text(encoding='utf-8').splitlines()
    start = name = None
    for i, line in enumerate(lines):
        m = FUNC.match(line)
        if m and start is None:
            start, name = i, m.group(1)
        elif start is not None and END.match(line):
            yield name, start + 1, '\n'.join(lines[start:i + 1])
            start = name = None


class ImGuiStackTest(unittest.TestCase):
    def test_no_pop_deeper_than_its_pushes(self):
        offenders = []
        checked = 0
        for path in sorted(ROOT.glob('core/**/*.nelua')):
            for name, line, body in functions(path):
                pushes = {'StyleColor': 0, 'StyleVar': 0}
                for kind in PUSH.findall(body):
                    pushes[kind] += 1
                for kind, count in POP.findall(body):
                    checked += 1
                    if int(count) > pushes[kind]:
                        offenders.append(
                            '%s:%d %s(): Pop%s(%s) but only %d Push%s* here'
                            % (path.relative_to(ROOT), line, name, kind,
                               count, pushes[kind], kind))
        self.assertGreater(checked, 0, 'found no imgui.Pop* calls to check')
        self.assertEqual(offenders, [], 'ImGui stack underflow:\n  ' + '\n  '.join(offenders))


if __name__ == '__main__':
    unittest.main()
