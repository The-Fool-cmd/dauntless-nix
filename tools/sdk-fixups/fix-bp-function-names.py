#!/usr/bin/env python3
"""Fix Dumper-7's Blueprint-event wrappers in a generated CppSDK (in place).

Dumper-7 (CppGenerator.cpp, the bUseDynamicLookup branch) emits, for every BlueprintEvent function,

    class UFunction* Func = InSDKUtils::FindFunctionChecked(this, GetStaticName(L"<OuterClass>", FnName));

i.e. the OUTER CLASS name where the FUNCTION name belongs. At run time the engine's FindFunctionChecked then aborts
the process: "Failed to find function BP_PlayerCharacter_C in BP_PlayerCharacter_C ..." (seen on the Ramsgate server
at the first player's TickStamina call). This replaces the name with the function's own name, taken from the
"// Function <Package>.<Class>.<Name>" comment Dumper-7 writes above each wrapper.

usage: fix-bp-function-names.py <CppSDK dir>
"""
import os, re, sys

COMMENT = re.compile(r'^// Function (?:[^.\s]+)\.([^.\s]+)\.(.+?)\s*$')
LOOKUP = re.compile(r'GetStaticName\((L"(?:[^"\\]|\\.)*"), FnName\)')

def fix_file(path: str) -> int:
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.readlines()
    fixed, outer, name = 0, None, None
    for i, line in enumerate(lines):
        m = COMMENT.match(line)
        if m:
            outer, name = m.group(1), m.group(2)
            continue
        m = LOOKUP.search(line)
        if m and name is not None:
            if m.group(1) != f'L"{outer}"':
                raise SystemExit(f"{path}:{i + 1}: unexpected lookup {m.group(1)} under {outer}.{name}")
            escaped = name.replace("\\", "\\\\").replace('"', '\\"')
            lines[i] = line[:m.start(1)] + f'L"{escaped}"' + line[m.end(1):]
            fixed += 1
            name = None
    if fixed:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.writelines(lines)
    return fixed

def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    total = 0
    for root, _, files in os.walk(sys.argv[1]):
        for fn in files:
            if fn.endswith(".cpp"):
                total += fix_file(os.path.join(root, fn))
    print(f"fixed {total} Blueprint-event lookups")

if __name__ == "__main__":
    main()
