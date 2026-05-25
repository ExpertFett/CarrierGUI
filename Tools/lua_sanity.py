#!/usr/bin/env python3
"""Rough Lua syntax sanity check: bracket balance + block/end balance.
Not a parser — catches the common 'missing end' / unbalanced brace mistakes.
Strips long-bracket strings, quoted strings, and comments before counting."""
import sys
import re


def strip_lua(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        m = re.match(r'\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            end = src.find(close, i + len(m.group(0)))
            i = (end + len(close)) if end != -1 else n
            continue
        if src[i:i + 2] == '--':
            lm = re.match(r'--\[(=*)\[', src[i:])
            if lm:
                close = ']' + lm.group(1) + ']'
                end = src.find(close, i + len(lm.group(0)))
                i = (end + len(close)) if end != -1 else n
                continue
            nl = src.find('\n', i)
            i = nl if nl != -1 else n
            continue
        ch = src[i]
        if ch in ('"', "'"):
            j = i + 1
            while j < n and src[j] != ch:
                if src[j] == '\\':
                    j += 1
                j += 1
            i = j + 1
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def check(path: str) -> bool:
    src = open(path, encoding='utf-8').read()
    code = strip_lua(src)
    paren = code.count('(') - code.count(')')
    brace = code.count('{') - code.count('}')
    brack = code.count('[') - code.count(']')
    words = re.findall(r'\b\w+\b', code)
    n_end = words.count('end')
    n_func = words.count('function')
    n_if = words.count('if')
    n_for = words.count('for')
    n_while = words.count('while')
    n_do = words.count('do')
    standalone_do = n_do - n_for - n_while
    expected_end = n_func + n_if + n_for + n_while + standalone_do
    ok = (paren == 0 and brace == 0 and brack == 0 and expected_end == n_end)
    name = path.replace('\\', '/').split('/')[-1]
    print(f"[{'OK' if ok else 'CHECK'}] {name}")
    print(f"    parens={paren:+d} braces={brace:+d} brackets={brack:+d}")
    print(f"    end={n_end} expected~={expected_end} "
          f"(func={n_func} if={n_if} for={n_for} while={n_while} do_standalone={standalone_do})")
    return ok


if __name__ == '__main__':
    all_ok = True
    for p in sys.argv[1:]:
        all_ok = check(p) and all_ok
    sys.exit(0 if all_ok else 1)
