# [Regex crate](https://crates.io/crates/regex) in Python

High-level Cython wrapper around a Rust dynamic library that implements
extremely fast regular-expression operations (matching, substitution,
splitting, multi-pattern search, etc.) using the [Rust Regex crate](https://crates.io/crates/regex).

The Rust side is compiled on-the-fly (if no pre-built .so/.dll/.dylib
is found) and the resulting symbols are accessed through [Cython](https://cython.readthedocs.io/).
Heavy work is done without the GIL; this file exposes a comfortable
Pythonic API with fallback to bytes/str overloads.

---

## Prerequisites

```sh
pip install rustcrateregex
```

> [!CAUTION]
> **MAKE SURE TO HAVE CYTHON, A C++ COMPILER AND RUST INSTALLED**


<!--  -->
---

## Table of Contents

1. [Basic Usage](#basic-usage)
2. [Multi-Pattern Matching](#multi-pattern-matching)
3. [Named Groups & `find_iter`](#named-groups--find_iter)
4. [Performance Comparison](#performance-comparison)
5. [Unicode Support](#unicode-support)
6. [Syntax Reference](#syntax-reference)
7. [More Examples](#more-examples)
8. [Trie Regex (Word-list)](#trie-regex-word-list)

---

## Basic Usage

```python
from rustcrateregex import RustRegex

# Create a RustRegex instance from a pattern supporting both str and bytes.
homer = RustRegex(r"Homer (.)\. Simpson")

# Test for a match (returns True or False).
assert homer.is_match("Homer J. Simpson")

# Find the first match: returns [start, end, match].
print(homer.find("Homer J. Simpson"))  # [0, 16, "Homer J. Simpson"]

# start and end values are in bytes, not characters!
print(homer.find("çç Homer J. Simpson"))  # [5, 21, 'Homer J. Simpson']

# Find all matches in a string or bytes; returns a flat list of matches.
all_matches = homer.find_all("This is my friend Homer J. Simpson Homer J. Simpson, ok?")
print(all_matches)  # ['Homer J. Simpson', 'Homer J. Simpson']

# Iterate over all matches with full group details.
# start and end values are in bytes, not characters!
for match in homer.find_iter("Homer J. Simpson"):
    print(
        match
    )  # [{'start': 0, 'end': 16, 'length': 16, 'group': 0, 'groupname': '', 'match': 'Homer J. Simpson'}, {'start': 6, 'end': 7, 'length': 1, 'group': 1, 'groupname': '', 'match': 'J'}]

# Splitting the haystack on the pattern:
print(
    homer.split("This is my friend Homer J. Simpson, ok?")
)  # ['This is my friend ', ', ok?']

# Keep delimiters in results:
print(
    homer.split_keep("This is my friend Homer J. Simpson, ok?")
)  # ['This is my friend ', 'Homer J. Simpson', ', ok?']

# Keep capture group contents as separate tokens:
print(
    homer.split_keep_groups("This is my friend Homer J. Simpson, ok?")
)  # ['This is my friend Homer ', 'J', '. Simpson, ok?']

# Perform substitutions (supports Rust-style $1 group references).
print(homer.sub("$1", "This is Homer J. Simpson!"))  # This is J!
print(
    homer.sub("$1", "Homer J. Simpson, Homer J. Simpson many times", count=1)
)  # J, Homer J. Simpson many times

# setting the limit of a compiled regex, defaults to 1024 * 1024 * 1024
RustRegex.set_regex_size_limit(1024 * 1024 * 1024 * 2)

# Clear the internal regex cache; useful after many dynamic patterns that are not used anymore.
RustRegex.clean_regex_cache()

```

---

## Multi-Pattern Matching

```python
patterns = [
    r"\w+",
    r"\d+",
    r"123(\d+)",
    r"x\w+",
    r"(?<first_number>\w+)\s+(?<second_number>\w+)",
    r"[[:digit:]]+[[:space:]]+[[:digit:]]+",
]

# Apply all patterns in a single pass over a str.
multi_str_results = list(RustRegex.find_regex_multi(patterns, "1234 1254"))
print(multi_str_results)

# Apply all patterns in a single pass over bytes (zero-copy).
multi_bytes_results = list(RustRegex.find_regex_multi(patterns, b"\x001234 1254\x00"))
print(multi_bytes_results)
```

---

## Named Groups & `find_iter`

```python
text = (
    "path/to/foo:54:Blue Harvest\n"
    "path/to/bar:90:Something, Something, Something, Dark Side\n"
    "path/to/baz:3:It's a Trap!"
)

# Use inline flags for multiline mode (?m) and extract named groups.
grep = RustRegex(r"(?m)^(?<file>[^:]+):(?<line>[0-9]+):(?<message>.+)$")

for item in grep.find_iter(text):
    print(item)

# Works identically on bytes input.
for item in grep.find_iter(text.encode("utf-8")):
    print(item)

# Simple named-group example.
greet = RustRegex(r"Hello (?<name>\w+)!")
print(list(greet.find_iter("Hello Murphy!")))
```

---

## Performance Comparison

```python
# Load a large text for benchmarking.
with requests.get(
    "https://github.com/hansalemaos/regex-benchmark/raw/refs/heads/master/input-text.txt"
) as r:
    haystack = r.text

rust_email_regex = RustRegex(r"[\w\.+-]+@[\w\.-]+\.[\w\.-]+")
re_email_regex = re.compile(r"[\w\.+-]+@[\w\.-]+\.[\w\.-]+")
cregex_email_regex = cregex.compile(r"[\w\.+-]+@[\w\.-]+\.[\w\.-]+")


# %timeit rust_email_regex.find_all(haystack)
# 10.8 ms ± 65.4 μs per loop (mean ± std. dev. of 7 runs, 100 loops each)
# encoding the string takes around 6.5 ms

# %timeit re_email_regex.findall(haystack)
# 255 ms ± 1.86 ms per loop (mean ± std. dev. of 7 runs, 1 loop each)

# %timeit cregex_email_regex.findall(haystack)
# 541 ms ± 28.7 ms per loop (mean ± std. dev. of 7 runs, 1 loop each)

print(
    "Are results the same? ",
    rust_email_regex.find_all(haystack)
    == re_email_regex.findall(haystack)
    == cregex_email_regex.findall(haystack),
)
########################################################################################################################
haystack_bytes = haystack.encode()
re_email_regex_bytes = re.compile(rb"[\w\.+-]+@[\w\.-]+\.[\w\.-]+")
cregex_email_regex_bytes = cregex.compile(rb"[\w\.+-]+@[\w\.-]+\.[\w\.-]+")


# %timeit rust_email_regex.find_all(haystack_bytes)
# 4.01 ms ± 83.1 μs per loop (mean ± std. dev. of 7 runs, 100 loops each)
# no encoding needed because the byte buffer is used directly in Rust

# %timeit re_email_regex_bytes.findall(haystack_bytes)
# 225 ms ± 16.1 ms per loop (mean ± std. dev. of 7 runs, 1 loop each)

# %timeit cregex_email_regex_bytes.findall(haystack_bytes)
# 501 ms ± 38.7 ms per loop (mean ± std. dev. of 7 runs, 1 loop each)

print(
    "Are results the same? ",
    rust_email_regex.find_all(haystack_bytes)
    == re_email_regex_bytes.findall(haystack_bytes)
    == cregex_email_regex_bytes.findall(haystack_bytes),
)

set(rust_email_regex.find_all(haystack_bytes)).symmetric_difference(
    re_email_regex_bytes.findall(haystack_bytes)
)

# results are not the same, Rust Regex recognizes (correctly) a UTF-8 encoded char
{b"M\xc3\xb4jEmail@Zoho.com", b"jEmail@Zoho.com"}

b"M\xc3\xb4jEmail@Zoho.com".decode()
# 'MôjEmail@Zoho.com'

########################################################################################################################

rust_uri_regex = RustRegex(r"[\w]+://[^/\s?#]+[^\s?#]+(?:\?[^\s#]*)?(?:#[^\s]*)?")
re_uri_regex = re.compile(r"[\w]+://[^/\s?#]+[^\s?#]+(?:\?[^\s#]*)?(?:#[^\s]*)?")
cregex_uri_regex = cregex.compile(
    r"[\w]+://[^/\s?#]+[^\s?#]+(?:\?[^\s#]*)?(?:#[^\s]*)?"
)


# %timeit rust_uri_regex.find_all(haystack)
# 12.5 ms ± 65.4 μs per loop (mean ± std. dev. of 7 runs, 100 loops each)

# %timeit rust_uri_regex.find_all(haystack_bytes)
# 6.6 ms ± 362 μs per loop (mean ± std. dev. of 7 runs, 100 loops each)

# %timeit re_uri_regex.findall(haystack)
# 185 ms ± 2 ms per loop (mean ± std. dev. of 7 runs, 1 loop each)

# %timeit cregex_uri_regex.findall(haystack)
# 312 ms ± 17 ms per loop (mean ± std. dev. of 7 runs, 1 loop each)

print(
    "Are results the same? ",
    rust_uri_regex.find_all(haystack)
    == re_uri_regex.findall(haystack)
    == cregex_uri_regex.findall(haystack),
)
########################################################################################################################

rust_ip_regex = RustRegex(
    r"(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])"
)
re_ip_regex = re.compile(
    r"(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])"
)
cregex_ip_regex = cregex.compile(
    r"(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9])"
)


# %timeit rust_ip_regex.find_all(haystack)
# 12.5 ms ± 58.7 μs per loop (mean ± std. dev. of 7 runs, 100 loops each)

# %timeit rust_ip_regex.find_all(haystack_bytes)
# 6.28 ms ± 309 μs per loop (mean ± std. dev. of 7 runs, 100 loops each)

# %timeit re_ip_regex.findall(haystack)
# 187 ms ± 2.31 ms per loop (mean ± std. dev. of 7 runs, 1 loop each)

# %timeit cregex_ip_regex.findall(haystack)
# 14 ms ± 92.1 μs per loop (mean ± std. dev. of 7 runs, 100 loops each)

print(
    "Are results the same? ",
    rust_ip_regex.find_all(haystack)
    == re_ip_regex.findall(haystack)
    == cregex_ip_regex.findall(haystack),
)

```

---

## Unicode Support

```python
# Emoji repetition
uni_pat = RustRegex(r"🙂+")
txt = "no🙂🙂pe"
print(uni_pat.is_match(txt))
print(uni_pat.find(txt))

# works with byte data too
print(uni_pat.is_match(txt.encode("utf-8")))
print(uni_pat.find(txt.encode("utf-8")))

RustRegex(r"\d{4}-\d{2}-\d{2}").find_all(r"𝟚𝟘𝟙𝟘-𝟘𝟛-𝟙𝟜 2010-03-11")
# ['𝟚𝟘𝟙𝟘-𝟘𝟛-𝟙𝟜', '2010-03-11']
RustRegex(r"(?-u:\d){4}-\d{2}-\d{2}").find_all(r"𝟚𝟘𝟙𝟘-𝟘𝟛-𝟙𝟜 2010-03-11")
# ['2010-03-11']
```

---

## Syntax Reference

See [Rust regex syntax](https://docs.rs/regex/latest/regex/index.html) for full details.
Here’s a quick-reference snippet:

```text
.             any character except new line (includes new line with s flag)
[0-9]         any ASCII digit
\d            digit (\p{Nd})
\D            not digit
\pX           Unicode character class identified by a one-letter name
\p{Greek}     Unicode character class (general category or script)
\PX           Negated Unicode character class identified by a one-letter name
\P{Greek}     negated Unicode character class (general category or script)

Character classes
[xyz]         A character class matching either x, y or z (union).
[^xyz]        A character class matching any character except x, y and z.
[a-z]         A character class matching any character in range a-z.
[[:alpha:]]   ASCII character class ([A-Za-z])
[[:^alpha:]]  Negated ASCII character class ([^A-Za-z])
[x[^xyz]]     Nested/grouping character class (matching any character except y and z)
[a-y&&xyz]    Intersection (matching x or y)
[0-9&&[^4]]   Subtraction using intersection and negation (matching 0-9 except 4)
[0-9--4]      Direct subtraction (matching 0-9 except 4)
[a-g~~b-h]    Symmetric difference (matching `a` and `h` only)
[\[\]]        Escaping in character classes (matching [ or ])
[a&&b]        An empty character class matching nothing

Repetitions
x*        zero or more of x (greedy)
x+        one or more of x (greedy)
x?        zero or one of x (greedy)
x*?       zero or more of x (ungreedy/lazy)
x+?       one or more of x (ungreedy/lazy)
x??       zero or one of x (ungreedy/lazy)
x{n,m}    at least n x and at most m x (greedy)
x{n,}     at least n x (greedy)
x{n}      exactly n x
x{n,m}?   at least n x and at most m x (ungreedy/lazy)
x{n,}?    at least n x (ungreedy/lazy)
x{n}?     exactly n x

Empty matches
^               the beginning of a haystack (or start-of-line with multi-line mode)
$               the end of a haystack (or end-of-line with multi-line mode)
\A              only the beginning of a haystack (even with multi-line mode enabled)
\z              only the end of a haystack (even with multi-line mode enabled)
\b              a Unicode word boundary (\w on one side and \W, \A, or \z on other)
\B              not a Unicode word boundary
\b{start}, \<   a Unicode start-of-word boundary (\W|\A on the left, \w on the right)
\b{end}, \>     a Unicode end-of-word boundary (\w on the left, \W|\z on the right))
\b{start-half}  half of a Unicode start-of-word boundary (\W|\A on the left)
\b{end-half}    half of a Unicode end-of-word boundary (\W|\z on the right)

Grouping
(exp)          numbered capture group (indexed by opening parenthesis)
(?P<name>exp)  named (also numbered) capture group (names must be alpha-numeric)
(?<name>exp)   named (also numbered) capture group (names must be alpha-numeric)
(?:exp)        non-capturing group
(?flags)       set flags within current group
(?flags:exp)   set flags for exp (non-capturing)

Flags
i     case-insensitive: letters match both upper and lower case
m     multi-line mode: ^ and $ match begin/end of line
s     allow . to match \n
R     enables CRLF mode: when multi-line mode is enabled, \r\n is used
U     swap the meaning of x* and x*?
u     Unicode support (enabled by default)
x     verbose mode, ignores whitespace and allow line comments (starting with `#`)

```

---

## More Examples

```python
# Example 1: digits vs non-digits
r = RustRegex(r"\d+")
print(r.find_all("abc123xyz 456"))
# → ['123', '456']

r2 = RustRegex(r"\D+")
print(r2.find_all("abc123xyz 456"))
# → ['abc', 'xyz ']

# Example 2: ASCII class subtraction (0–9 except 4)
r3 = RustRegex(r"[0-9--4]+")
print(r3.find_all("0123456789"))
# → ['0123', '56789']

# Example 3: lazy vs greedy quantifier
r4 = RustRegex(r"\".*?\"")  # lazy: shortest quoted
print(r4.find_all('say "hi" and then "hello world"'))
# → ['"hi"', '"hello world"']

r5 = RustRegex(r"\".*\"")  # greedy: whole string
print(r5.find('say "hi" and then "hello world"'))
# → [4, 31, '"hi" and then "hello world"']

# Example 4: word boundaries
r6 = RustRegex(
    r"\bpython\b",
)
print(r6.find_all("python2 vs python pythonista"))
# → ['python']

# Example 5: named groups & flags
r7 = RustRegex(r"(?i)(?P<lang>rust|python)")
print(list(r7.find_iter("Rust and PYTHON are awesome")))
# → [[{'start': 0, 'end': 4, 'length': 4, 'group': 0, 'groupname': '', 'match': 'Rust'}, {'start': 0, 'end': 4, 'length': 4, 'group': 1, 'groupname': 'lang', 'match': 'Rust'}], [{'start': 9, 'end': 15, 'length': 6, 'group': 0, 'groupname': '', 'match': 'PYTHON'}, {'start': 9, 'end': 15, 'length': 6, 'group': 1, 'groupname': 'lang', 'match': 'PYTHON'}]]

# Example 6: Unicode scripts
r8 = RustRegex(r"[\p{Greek}]+")
print(r8.find_all("abc ΔδΔ xyz Ω"))
# → ['ΔδΔ', 'Ω']

# Example 7: multiline & dot-all flags
text = "first.line\nsecond.line"
r9 = RustRegex(r"(?s)^.*$")
print(r9.find_all(text))
# → ['first.line\nsecond.line']

r10 = RustRegex(r"(?m)^(\w+)\.")
print(list(r10.find_iter(text)))
# → [[{'start': 0, 'end': 6, 'length': 6, 'group': 0, 'groupname': '', 'match': 'first.'}, {'start': 0, 'end': 5, 'length': 5, 'group': 1, 'groupname': '', 'match': 'first'}], [{'start': 11, 'end': 18, 'length': 7, 'group': 0, 'groupname': '', 'match': 'second.'}, {'start': 11, 'end': 17, 'length': 6, 'group': 1, 'groupname': '', 'match': 'second'}]]


# More examples
print(RustRegex(r"[\pN\p{Greek}\p{Cherokee}]+").find_all(r"abcΔᎠβⅠᏴγδⅡxyz"))
# → ['ΔᎠβⅠᏴγδⅡ']
print(RustRegex(r"[\p{Greek}&&\pL]+").find_all(r"ΔδΔ𐅌ΔδΔ"))
# → ['ΔδΔ', 'ΔδΔ']
print(RustRegex(r"\b{start}\w+\b{end}").find_all(r"..dd..dda..dd.."))
# → ['dd', 'dda', 'dd']
print(list(RustRegex(r"(?P<name>\b{start}\w+\b{end})").find_iter(r"..dd..dda..dd..")))
# → [[{'start': 2, 'end': 4, 'length': 2, 'group': 0, 'groupname': '', 'match': 'dd'}, {'start': 2, 'end': 4, 'length': 2, 'group': 1, 'groupname': 'name', 'match': 'dd'}], [{'start': 6, 'end': 9, 'length': 3, 'group': 0, 'groupname': '', 'match': 'dda'}, {'start': 6, 'end': 9, 'length': 3, 'group': 1, 'groupname': 'name', 'match': 'dda'}], [{'start': 11, 'end': 13, 'length': 2, 'group': 0, 'groupname': '', 'match': 'dd'}, {'start': 11, 'end': 13, 'length': 2, 'group': 1, 'groupname': 'name', 'match': 'dd'}]]
print(list(RustRegex(r"(?i)a+(?-i)b+").find_iter(r"AaAaAbbBBBb")))
# → [[{'start': 0, 'end': 7, 'length': 7, 'group': 0, 'groupname': '', 'match': 'AaAaAbb'}]]

phone_number_regex = RustRegex(r"[0-9]{3}-[0-9]{3}-[0-9]{4}")
phone_number_str = "phone: 111-222-3333 phone: 444-555-6666"
print(phone_number_regex.is_match(phone_number_str))
# True
print(phone_number_regex.find_all(phone_number_str))
print(phone_number_regex.findall(phone_number_str))
# ['111-222-3333', '444-555-6666']
print(phone_number_regex.split(phone_number_str))
# ['phone: ', ' phone: ', '']
print(phone_number_regex.find(phone_number_str))
# [7, 19, '111-222-3333']
print(list(phone_number_regex.find_iter(phone_number_str)))
print(list(phone_number_regex.finditer(phone_number_str)))
# [[{'start': 7, 'end': 19, 'length': 12, 'group': 0, 'groupname': '', 'match': '111-222-3333'}], [{'start': 27, 'end': 39, 'length': 12, 'group': 0, 'groupname': '', 'match': '444-555-6666'}]]
phone_number_regex_with_groups = RustRegex(
    r"(?<group1>[0-9]{3})-(?<group2>[0-9]{3})-(?<group3>[0-9]{4})"
)
print(phone_number_regex_with_groups.find_all_groups(phone_number_str))
# [['111', '222', '3333'], ['444', '555', '6666']]
print(phone_number_regex_with_groups.split_keep(phone_number_str))
# ['phone: ', '111-222-3333', ' phone: ', '444-555-6666']
animal_haystack = r"""\
rabbit         54 true
groundhog 2 true
does not match
fox   109    false
"""
animal_regex = RustRegex(r"(?m)^\s*(\S+)\s+([0-9]+)\s+(true|false)\s*$")
print(list(animal_regex.find_iter(animal_haystack)))
[
    [
        {
            "start": 2,
            "end": 24,
            "length": 22,
            "group": 0,
            "groupname": "",
            "match": "rabbit         54 true",
        },
        {
            "start": 2,
            "end": 8,
            "length": 6,
            "group": 1,
            "groupname": "",
            "match": "rabbit",
        },
        {
            "start": 17,
            "end": 19,
            "length": 2,
            "group": 2,
            "groupname": "",
            "match": "54",
        },
        {
            "start": 20,
            "end": 24,
            "length": 4,
            "group": 3,
            "groupname": "",
            "match": "true",
        },
    ],
    [
        {
            "start": 25,
            "end": 41,
            "length": 16,
            "group": 0,
            "groupname": "",
            "match": "groundhog 2 true",
        },
        {
            "start": 25,
            "end": 34,
            "length": 9,
            "group": 1,
            "groupname": "",
            "match": "groundhog",
        },
        {
            "start": 35,
            "end": 36,
            "length": 1,
            "group": 2,
            "groupname": "",
            "match": "2",
        },
        {
            "start": 37,
            "end": 41,
            "length": 4,
            "group": 3,
            "groupname": "",
            "match": "true",
        },
    ],
    [
        {
            "start": 57,
            "end": 76,
            "length": 19,
            "group": 0,
            "groupname": "",
            "match": "fox   109    false\n",
        },
        {
            "start": 57,
            "end": 60,
            "length": 3,
            "group": 1,
            "groupname": "",
            "match": "fox",
        },
        {
            "start": 63,
            "end": 66,
            "length": 3,
            "group": 2,
            "groupname": "",
            "match": "109",
        },
        {
            "start": 70,
            "end": 75,
            "length": 5,
            "group": 3,
            "groupname": "",
            "match": "false",
        },
    ],
]
##################################################################################################

print(
    list(
        RustRegex(r"(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})").find_iter(
            "What do 1865-04-14, 1881-07-02, 1901-09-06 and 1963-11-22 have in common?"
        )
    )
)

[
    [
        {
            "start": 8,
            "end": 18,
            "length": 10,
            "group": 0,
            "groupname": "",
            "match": "1865-04-14",
        },
        {
            "start": 8,
            "end": 12,
            "length": 4,
            "group": 1,
            "groupname": "y",
            "match": "1865",
        },
        {
            "start": 13,
            "end": 15,
            "length": 2,
            "group": 2,
            "groupname": "m",
            "match": "04",
        },
        {
            "start": 16,
            "end": 18,
            "length": 2,
            "group": 3,
            "groupname": "d",
            "match": "14",
        },
    ],
    [
        {
            "start": 20,
            "end": 30,
            "length": 10,
            "group": 0,
            "groupname": "",
            "match": "1881-07-02",
        },
        {
            "start": 20,
            "end": 24,
            "length": 4,
            "group": 1,
            "groupname": "y",
            "match": "1881",
        },
        {
            "start": 25,
            "end": 27,
            "length": 2,
            "group": 2,
            "groupname": "m",
            "match": "07",
        },
        {
            "start": 28,
            "end": 30,
            "length": 2,
            "group": 3,
            "groupname": "d",
            "match": "02",
        },
    ],
    [
        {
            "start": 32,
            "end": 42,
            "length": 10,
            "group": 0,
            "groupname": "",
            "match": "1901-09-06",
        },
        {
            "start": 32,
            "end": 36,
            "length": 4,
            "group": 1,
            "groupname": "y",
            "match": "1901",
        },
        {
            "start": 37,
            "end": 39,
            "length": 2,
            "group": 2,
            "groupname": "m",
            "match": "09",
        },
        {
            "start": 40,
            "end": 42,
            "length": 2,
            "group": 3,
            "groupname": "d",
            "match": "06",
        },
    ],
    [
        {
            "start": 47,
            "end": 57,
            "length": 10,
            "group": 0,
            "groupname": "",
            "match": "1963-11-22",
        },
        {
            "start": 47,
            "end": 51,
            "length": 4,
            "group": 1,
            "groupname": "y",
            "match": "1963",
        },
        {
            "start": 52,
            "end": 54,
            "length": 2,
            "group": 2,
            "groupname": "m",
            "match": "11",
        },
        {
            "start": 55,
            "end": 57,
            "length": 2,
            "group": 3,
            "groupname": "d",
            "match": "22",
        },
    ],
]

# ignoring whitespace
print(
    RustRegex(r"""(?x)
  (?P<y>\d{4}) # the year, including all Unicode digits
  -
  (?P<m>\d{2}) # the month, including all Unicode digits
  -
  (?P<d>\d{2}) # the day, including all Unicode digits
""").sub("$m/$d/$y", "1973-01-05, 1975-08-25 and 1980-10-18")
)

# match longer matches
print(RustRegex(r"samwise|sam").find("samwise"))
print(RustRegex(r"sam|samwise").find("samwise"))
# [0, 7, "samwise"]
# [0, 3, "sam"]

# =============================================================================
# Prefer ascii over unicode
# =============================================================================
import string

big_string = string.ascii_letters * 10000
regex_ascii_only = RustRegex(r"(?-u:\w){200}")
regex_ascii_unicode = RustRegex(r"\w{200}")
# %timeit regex_ascii_only.find_all(big_string)
# 2.68 ms ± 221 μs per loop (mean ± std. dev. of 7 runs, 100 loops each)

# generates a huge regex https://docs.rs/regex/latest/regex/struct.RegexBuilder.html#method.size_limit
# %timeit regex_ascii_unicode.find_all(big_string)
# 412 ms ± 3.24 ms per loop (mean ± std. dev. of 7 runs, 1 loop each)

```

---

## Trie Regex (Word-List)

```python
python_text = r"""Python is a high-level, general-purpose programming language. Its design philosophy emphasizes code readability with the use of significant indentation.[33] Python is dynamically type-checked and garbage-collected. It supports multiple programming paradigms, including structured (particularly procedural), object-oriented and functional programming. It is often described as a "batteries included" language due to its comprehensive standard library.[34][35] Guido van Rossum began working on Python in the late 1980s as a successor to the ABC programming language, and he first released it in 1991 as Python 0.9.0.[36] Python 2.0 was released in 2000. Python 3.0, released in 2008, was a major revision not completely backward-compatible with earlier versions. Python 2.7.18, released in 2020, was the last release of Python 2.[37] Python consistently ranks as one of the most popular programming languages, and it has gained widespread use in the machine learning community.[38][39][40][41]"""

word_list = [
    "Python",
    "Rossum",
    "a",
    "and",
    "as",
    "backward-compatible",
    "began",
    "code",
    "completely",
    "comprehensive",
    "consistently",
    "described",
    "design",
    "due",
    "dynamically",
    "earlier",
    "emphasizes",
    "first",
    "functional",
    "gained",
    "garbage-collected",
    "general-purpose",
    "has",
    "he",
    "high-level",
    "in",
    "including",
    "is",
    "it",
    "its",
    "language",
    "last",
    "late",
    "learning",
    "machine",
    "major",
    "most",
    "multiple",
    "not",
    "object-oriented",
    "of",
    "often",
    "on",
    "one",
    "paradigms",
    "philosophy",
    "popular",
    "programming",
    "ranks",
    "readability",
    "release",
    "released",
    "revision",
    "significant",
    "standard",
    "structured",
    "successor",
    "supports",
    "the",
    "to",
    "type-checked",
    "use",
    "van",
    "was",
    "widespread",
    "with",
    "working",
]

wordlistregex = RustRegex.from_wordlist(
    word_list,
    add_before="",
    add_after="",
    boundary_right=True,
    boundary_left=True,
    capture=False,
    match_whole_line=False,
)
print(repr(wordlistregex))
'RustRegex("\\b(?:Python|Rossum|a(?:(?:nd|s))?|b(?:ackward-compatible|egan)|co(?:de|mp(?:letely|rehensive)|nsistently)|d(?:es(?:cribed|ign)|ue|ynamically)|e(?:arlier|mphasizes)|f(?:irst|unctional)|g(?:a(?:ined|rbage-collected)|eneral-purpose)|h(?:as|igh-level|e)|i(?:n(?:cluding)?|ts?|s)|l(?:a(?:nguage|st|te)|earning)|m(?:a(?:chine|jor)|ost|ultiple)|not|o(?:bject-oriented|f(?:ten)?|ne?)|p(?:aradigms|hilosophy|opular|rogramming)|r(?:anks|e(?:adability|leased?|vision))|s(?:ignificant|t(?:andard|ructured)|u(?:ccessor|pports))|t(?:he|ype-checked|o)|use|van|w(?:as|i(?:despread|th)|orking))\\b")'
print(wordlistregex.find_all(python_text))
# ['Python', 'is', 'a', 'high-level', 'general-purpose', 'programming', 'language', 'design', 'philosophy', 'emphasizes', 'code', 'readability', 'with', 'the', 'use', 'of', 'significant', 'Python', 'is', 'dynamically', 'type-checked', 'and', 'garbage-collected', 'supports', 'multiple', 'programming', 'paradigms', 'including', 'structured', 'object-oriented', 'and', 'functional', 'programming', 'is', 'often', 'described', 'as', 'a', 'language', 'due', 'to', 'its', 'comprehensive', 'standard', 'van', 'Rossum', 'began', 'working', 'on', 'Python', 'in', 'the', 'late', 'as', 'a', 'successor', 'to', 'the', 'programming', 'language', 'and', 'he', 'first', 'released', 'it', 'in', 'as', 'Python', 'Python', 'was', 'released', 'in', 'Python', 'released', 'in', 'was', 'a', 'major', 'revision', 'not', 'completely', 'backward-compatible', 'with', 'earlier', 'Python', 'released', 'in', 'was', 'the', 'last', 'release', 'of', 'Python', 'Python', 'consistently', 'ranks', 'as', 'one', 'of', 'the', 'most', 'popular', 'programming', 'and', 'it', 'has', 'gained', 'widespread', 'use', 'in', 'the', 'machine', 'learning']

```

---

