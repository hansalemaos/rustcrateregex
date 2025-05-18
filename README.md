# [Regex crate](https://crates.io/crates/regex) in Python

## Use the [fastest Regex](https://github.com/BurntSushi/rebar) engine ever made in Python

### `pip install rustcrateregex`

#### Important 1: Rust (cargo), Cython and a C++ compiler must be installed!

#### Important 2: Don't use this function in threads since the lib shares a global C++ vector for the results!

```py
from rustcrateregex import rust_regex
from time import perf_counter
import re
import regex as cregex  # Fast Regex engine with many nice features: https://pypi.org/project/regex/

# https://www.kaggle.com/datasets/vishnu0399/server-logs?resource=download&select=logfiles.log
with open(r"C:\Users\hansc\Downloads\archive\logfiles.log", mode="rb") as f:
    testbytes = f.read()

# regex for bytes - currently bytes only
regex = rb"\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[1-9])\.)(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])\.){2}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])\b"

start = perf_counter()
result_rust = rust_regex((regex), (testbytes))
print(perf_counter() - start)

start = perf_counter()
result_py = [(x.start(), x.end()) for x in re.finditer((regex), testbytes)]
print(perf_counter() - start)


start = perf_counter()
result_cregex = [(x.start(), x.end()) for x in cregex.finditer((regex), testbytes)]
print(perf_counter() - start)

print("All the same: ", result_rust == result_py == result_cregex)


# Output:
# 0.6047223000005033 # Rust Regex
# 4.6312387999996645 # Python Regex
# 3.5070090999997774 # Regex
# All the same:  True
```


