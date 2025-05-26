# High-level Cython wrapper around a Rust dynamic library that implements
# extremely fast regular-expression operations (matching, substitution,
# splitting, multi-pattern search, etc.).

# The Rust side is compiled on-the-fly (if no pre-built .so/.dll/.dylib
# is found) and the resulting symbols are accessed through *ctypes*.
# Heavy work is done without the GIL; this file exposes a comfortable
# Pythonic API with fallback to bytes/str overloads.

import cython
cimport cython
import os
import ctypes
from libcpp.vector cimport vector
from libcpp.utility cimport pair
from libcpp.string cimport string as cstring
import shutil
from libc.stdint cimport *
from libcpp.map cimport map as cppmap
from libcpp.unordered_map cimport unordered_map
from operator import itemgetter as operator_itemgetter
from libc.stdlib cimport malloc, free
from libc.string cimport strdup

cdef:
    dict _special_chars_map = {i: '\\' + chr(i) for i in b'()[]{}?*+|^$\\.'}


# ----------------------- function pointer typedefs for rust functions ---------------------- #

ctypedef void (*c_get_regex_groups)(size_t, const char*, void*, size_t) noexcept nogil
ctypedef void (*r_get_regex_groups)(const char*, c_get_regex_groups*, void*) noexcept nogil
ctypedef void (*c_replace_string)(size_t, const char*, void*) noexcept nogil
ctypedef void (*r_replace_string)(const char*, const char*, const char*, size_t, c_replace_string*, void*) noexcept nogil
ctypedef void (*c_find_iter)(size_t, size_t, size_t, void*) noexcept nogil
ctypedef void (*r_find_iter)(const char*, const char*, c_find_iter*, void*, size_t) noexcept nogil
ctypedef void (*c_split)(size_t, const char*, void*) noexcept nogil
ctypedef void (*r_split)(const char*, const char*, size_t, c_split*, void*) noexcept nogil
ctypedef void (*c_find_iter_multiple)(size_t, size_t, size_t, size_t, void*) noexcept nogil
ctypedef void (*r_find_iter_multiple)(const char**, size_t, const char*, c_find_iter_multiple*, void*) noexcept nogil
ctypedef void (*r_find_iter_multiple_bytes)(const char**, size_t, const char*, size_t, c_find_iter_multiple*, void*) noexcept nogil
ctypedef size_t (*r_is_match)(const char*, const char*) noexcept nogil
ctypedef void (*c_find)(size_t, size_t, void*) noexcept nogil
ctypedef void (*r_find)(const char*, const char*, c_find*, void*, size_t) noexcept nogil
ctypedef size_t (*r_is_match_bytes)(const char*, const char*, size_t) noexcept nogil
ctypedef void (*r_find_bytes)(const char*, const char*, size_t, c_find*, void*, size_t) noexcept nogil
ctypedef void (*r_find_iter_bytes)(const char*, const char*, size_t, c_find_iter*, void*, size_t) noexcept nogil
ctypedef void (*c_replace_string_bytes)(size_t, const char*, void*) noexcept nogil
ctypedef void (*r_replace_string_bytes)(const char*, const char*, size_t, const char*, size_t, size_t, c_replace_string_bytes*, void*) noexcept nogil
ctypedef void (*c_split_bytes)(size_t, const char*, void*) noexcept nogil
ctypedef void (*r_split_bytes)(const char*, const char*, size_t, size_t, c_split_bytes*, void*) noexcept nogil
ctypedef void (*r_clean_regex_cache)() noexcept nogil
ctypedef void (*r_set_regex_size_limit)(size_t) noexcept nogil

cdef convert_to_normal_dict_simple(object di):
    """
    Recursively turn every *MultiKeyDict* node inside *di* into a normal
    builtin dict, leaving any other mapping types untouched.

    Parameters
    ----------
    di : Any
        Arbitrary Python object that may contain nested *MultiKeyDict*s.

    Returns
    -------
    dict | object
        A deep-copied structure in which all *MultiKeyDict* instances
        were replaced by plain dict objects.
    """
    if isinstance(di, MultiKeyDict):
        di = {k: convert_to_normal_dict_simple(v) for k, v in di.items()}
    return di

class MultiKeyDict(dict):
    """
    Nested dictionary that allows hierarchical access through *list* keys.

    Examples
    --------
    >>> d = MultiKeyDict()
    >>> d[['foo', 'bar']] = 1          # equivalent to d['foo']['bar'] = 1
    >>> d[['foo', 'bar']]
    1
    >>> d.to_dict()
    {'foo': {'bar': 1}}
    """
    def __init__(self, seq=None, **kwargs):
        """
        Parameters
        ----------
        seq : Mapping | Iterable, optional
            Initial data used to populate the dict.
        **kwargs
            Additional key/value pairs forwarded to dict.__init__.
        """
        if seq:
            super().__init__(seq, **kwargs)

        def convert_dict(di):
            """Ensure nested *dict* objects become *MultiKeyDict*s."""
            if (isinstance(di, dict) and not isinstance(di, self.__class__)) or (
                hasattr(di, "items") and hasattr(di, "keys") and hasattr(di, "keys")
            ):
                ndi = self.__class__(
                    {},
                )
                for k, v in di.items():
                    ndi[k] = convert_dict(v)
                return ndi
            return di

        for key in self:
            self[key] = convert_dict(self[key])

    def __str__(self):
        return str(self.to_dict())

    def __missing__(self, key): # auto-create intermediate nodes
        self[key] = self.__class__({})
        return self[key]

    def __repr__(self):
        return self.__str__()

    def __delitem__(self, i):
        if isinstance(i, list):
            if len(i) > 1:
                lastkey = i[len(i)-1]
                i = i[:len(i)-1]
                it = iter(i)
                firstkey = next(it)
                value = self[firstkey]
                for element in it:
                    value = operator_itemgetter(element)(value)
                del value[lastkey]
            else:
                super().__delitem__(i[0])
        else:
            super().__delitem__(i)

    def __getitem__(self, key, /):
        if isinstance(key, list):
            if len(key) > 1:
                it = iter(key)
                firstkey = next(it)
                value = self[firstkey]
                for element in it:
                    value = operator_itemgetter(element)(value)
                return value
            else:
                return super().__getitem__(key[0])
        else:
            return super().__getitem__(key)

    def __setitem__(self, i, item):
        if isinstance(i, list):
            if len(i) > 1:
                lastkey = i[len(i)-1]
                i = i[:len(i)-1]
                it = iter(i)
                firstkey = next(it)
                value = self[firstkey]
                for element in it:
                    value = operator_itemgetter(element)(value)
                value[lastkey] = item
            else:
                return super().__setitem__(i[0], item)
        else:
            return super().__setitem__(i, item)

    def to_dict(self):
        """
        Return a *pure* Python representation where all nested
        *MultiKeyDict* instances become plain dict objects.
        """
        return convert_to_normal_dict_simple(self)

    def update(self, other, /, **kwds):
        other = self.__class__(other)
        super().update(other, **kwds)

    def get(self, key, default=None):
        v = default
        if not isinstance(key, list):
            return super().get(key, default)
        else:
            if len(key) > 1:
                it = iter(key)
                firstkey = next(it)
                value = self[firstkey]
                for element in it:
                    if element in value:
                        value = operator_itemgetter(element)(value)
                    else:
                        return default
            else:
                return super().get(key[0], default)
            return value

    def pop(self, key, default=None):
        if not isinstance(key, list):
            return super().pop(key, default)

        elif len(key) == 1:
            return super().pop(key[0], default)
        else:
            return self._del_and_return(key, default)

    def _del_and_return(self, key, default=None):
        newkey = key[:len(key)-1]
        delkey = key[len(key)-1]
        it = iter(newkey)
        firstkey = next(it)
        value = self[firstkey]
        for element in it:
            if element in value:
                value = operator_itemgetter(element)(value)
            else:
                return default

        value1 = value[delkey]
        del value[delkey]
        return value1

    def reversed(self):
        return reversed(list(iter(self.keys())))



class Trie:
    """
    Lightweight prefix-tree used solely for composing a single regular
    expression that matches any word in a given list.

    Call :meth:regex_from_words then :meth:compile to generate a
    ready-to-use regex string.
    """
    def __init__(self):
        self.data = MultiKeyDict({})

    def _add(self, word: str):
        """Insert *word* into the trie (internal use)."""
        cdef:
            list word2 = list(word)
        word2.append("")
        self.data[word2] = 1

    def _quote(self, char_):
        """Escape regex metacharacters in *char_*."""
        return char_.translate(_special_chars_map)

    @cython.boundscheck(True)
    @cython.nonecheck(True)
    def _pattern(self, pdata):
        """
        Recursively build a regex fragment from nested trie *pdata*.
        Returns None when *pdata* represents a terminal leaf.
        """
        cdef:
            list alt
            list cc
            bint cconly
            str result
        data = pdata
        if "" in data and len(data) == 1:
            return None
        alt = []
        cc = []
        q = 0
        for char_ in sorted(data):
            if isinstance(data[char_], dict):
                qu = self._quote(char_)
                try:
                    recurse = self._pattern(data[char_])
                    alt.append(qu + recurse)
                except Exception:
                    cc.append(qu)
            else:
                q = 1
        cconly = not len(alt) > 0
        if len(cc) > 0:
            if len(cc) == 1:
                alt.append(cc[0])
            else:
                alt.append("[" + "".join(cc) + "]")
        if len(alt) == 1:
            result = alt[0]
        else:
            result = "(?:" + "|".join(alt) + ")"
        if q:
            if cconly:
                result += "?"
            else:
                result = f"(?:{result})?"
        return result

    def _get_pattern(self):
        """Return the root-level regex fragment for the whole trie."""
        return self._pattern(self.data)

    def compile(
        self,
        str add_before="",
        str add_after="",
        bint boundary_right = False,
        bint boundary_left = False,
        bint capture = False,
        bint match_whole_line = False,
    ):
        """
        Assemble the final regex string with optional anchors / wrappers.

        Parameters
        ----------
        add_before, add_after : str
            Custom text prepended or appended to the generated pattern.
        boundary_right, boundary_left : bool
            Add \\b word boundaries on the respective sides.
        capture : bool
            If *True* the whole pattern is wrapped in a *capturing* group
            instead of a non-capturing one.
        match_whole_line : bool
            Surround pattern with ^\\s* … \\s*$ so it matches a full
            (possibly whitespace-padded) line.

        Returns
        -------
        str
            The final regular-expression string.
        """
        cdef:
            str anfang = ""
            str ende = ""

        if match_whole_line is True:
            anfang += r"^\s*"
        if boundary_right is True:
            ende += r"\b"
        if capture is True:
            anfang += "("
        if boundary_left is True:
            anfang += r"\b"
        if capture is True:
            ende += ")"

        if match_whole_line is True:
            ende += r"\s*$"
        return f"{add_before}{anfang}{self._get_pattern()}{ende}{add_after}"


    def regex_from_words(
        self,
        list[str] words,
    ):
        """
        Populate the trie with *words* and return self for chaining.
        """
        cdef:
            Py_ssize_t i
        for i in range(len(words)):
            self._add(words[i])
        return self

ctypedef struct regex_match:
    size_t g
    size_t s
    size_t e

ctypedef struct regex_match_multi:
    size_t i
    size_t g
    size_t s
    size_t e


cdef:
    cstring empty_string = <cstring>b""
    cstring get_regex_groups = cstring(b"get_regex_groups")
    cstring replace_string = cstring(b"replace_string")
    cstring find_iter = cstring(b"find_iter")
    cstring split = cstring(b"split")
    cstring find_iter_multiple = cstring(b"find_iter_multiple")
    cstring find_iter_multiple_bytes = cstring(b"find_iter_multiple_bytes")
    cstring is_match = cstring(b"is_match")
    cstring find = cstring(b"find")
    cstring replace_string_bytes = cstring(b"replace_string_bytes")
    cstring find_iter_bytes = cstring(b"find_iter_bytes")
    cstring split_bytes = cstring(b"split_bytes")
    cstring is_match_bytes = cstring(b"is_match_bytes")
    cstring find_bytes = cstring(b"find_bytes")
    cstring clean_regex_cache = cstring(b"clean_regex_cache")
    cstring set_regex_size_limit = cstring(b"set_regex_size_limit")

    str this_folder = os.path.dirname(__file__)
    str file_win = os.path.join(this_folder,"target","release","regex_dll.dll")
    str file_linux = os.path.join(this_folder,"target","release","regex_dll.so")
    str file_mac = os.path.join(this_folder,"target","release","regex_dll.dylib")
    str rust_source_folder = os.path.join(this_folder,"src")
    str rust_source_file = os.path.join(this_folder,"src", "lib.rs")
    str rust_source = os.path.join(this_folder, "lib.rs")
    list _func_cache = []
    list _possible_files = [file_win, file_linux, file_mac]


cdef getfile():
    """
    Return the first Rust dynamic-library path that exists in
    _possible_files or None when none of the candidates is
    present.  The helper is OS-agnostic and therefore checks in the
    order: .dll → .so → .dylib.
    """
    for file in _possible_files:
        if os.path.exists(file):
            return file
    return None

cdef get_or_compile_dll():
    """
    Locate the pre-built Rust shared library or build it on the fly.

    Workflow
    --------
    1. Call :func:getfile - if it returns a path, we're done.
    2. Otherwise copy the vendored lib.rs into src/ and run
        cargo build --release inside the package directory.
    3. Re-run :func:getfile and return its result.

    Raises
    ------
    OSError
        If the file is still missing after a successful cargo build.
    """
    filepath=getfile()
    if not filepath:
        old_dir=os.getcwd()
        os.chdir(this_folder)
        os.makedirs(rust_source_folder,exist_ok=True)
        if os.path.exists(rust_source_file):
            os.remove(rust_source_file)
        shutil.copyfile(rust_source,rust_source_file)
        os.system("cargo build --release")
        os.chdir(old_dir)
        filepath=getfile()
        if not filepath:
            raise OSError("Dynamic library not found")
    return filepath

cdef unordered_map[cstring,void*] get_c_function_ptr(str dllpathstr):
    """
    Load dllpathstr with ctypes and collect raw C function
    pointers into an unordered_map keyed by the exported symbol
    names (kept as cstring constants near the top of the file).

    A reference to the loaded library object is stored in the global
    _func_cache list so that the DLL/so/dylib cannot be unloaded
    prematurely by Python's garbage collector.
    """
    cdef:
        unordered_map[cstring,void*] func_dict
    cta = ctypes.cdll.LoadLibrary(dllpathstr)
    _func_cache.append(cta)
    func_dict[get_regex_groups]=(<void*><size_t>ctypes.addressof(cta.get_regex_groups))
    func_dict[replace_string]=(<void*><size_t>ctypes.addressof(cta.replace_string))
    func_dict[find_iter]=(<void*><size_t>ctypes.addressof(cta.find_iter))
    func_dict[split]=(<void*><size_t>ctypes.addressof(cta.split))
    func_dict[find_iter_multiple]=(<void*><size_t>ctypes.addressof(cta.find_iter_multiple))
    func_dict[find_iter_multiple_bytes]=(<void*><size_t>ctypes.addressof(cta.find_iter_multiple_bytes))
    func_dict[is_match]=(<void*><size_t>ctypes.addressof(cta.is_match))
    func_dict[find]=(<void*><size_t>ctypes.addressof(cta.find))
    func_dict[replace_string_bytes]=(<void*><size_t>ctypes.addressof(cta.replace_string_bytes))
    func_dict[find_iter_bytes]=(<void*><size_t>ctypes.addressof(cta.find_iter_bytes))
    func_dict[split_bytes]=(<void*><size_t>ctypes.addressof(cta.split_bytes))
    func_dict[is_match_bytes]=(<void*><size_t>ctypes.addressof(cta.is_match_bytes))
    func_dict[find_bytes]=(<void*><size_t>ctypes.addressof(cta.find_bytes))
    func_dict[clean_regex_cache]=(<void*><size_t>ctypes.addressof(cta.clean_regex_cache))
    func_dict[set_regex_size_limit]=(<void*><size_t>ctypes.addressof(cta.set_regex_size_limit))

    return func_dict

# ------------------------------------------------------------------ #
#                       Callbacks to get the results from Rust       #
# ------------------------------------------------------------------ #


cdef void callback_get_regex_groups(size_t group, const char* name, void* result, size_t length) noexcept nogil:
    cdef:
        size_t i
        cstring group_name
    if not name:
        (<cppmap[size_t,cstring]*>result)[0][group]=empty_string
    else:
        group_name.reserve(length)
        for i in range(length):
            group_name+=name[i]
        (<cppmap[size_t,cstring]*>result)[0][group]=group_name

cdef void callback_replace_string(size_t length, const char* ptr_result_string , void *result) noexcept nogil:
    cdef:
        size_t i
        cstring* s = <cstring*>result
    for i in range(length):
        s[0]+=ptr_result_string[i]

cdef void callback_replace_string_bytes(size_t length, const char* ptr_result_string , void *result) noexcept nogil:
    cdef:
        size_t i
        vector[uint8_t]* s = <vector[uint8_t]*>result
    for i in range(length):
        s[0].emplace_back(<uint8_t>ptr_result_string[i])

cdef void callback_find_iter(size_t group, size_t start, size_t end, void* results) noexcept nogil:
    if group==0:
        (<vector[vector[regex_match]]*>results)[0].emplace_back()
    (<vector[vector[regex_match]]*>results)[0].back().emplace_back(regex_match(group,start,end))

cdef void callback_split(size_t length, const char* ptr_result_string , void *result) noexcept nogil:
    cdef:
        size_t i
        cstring s
    s.reserve(length)
    for i in range(length):
        s+=ptr_result_string[i]
    (<vector[cstring]*>(result))[0].emplace_back(s)

cdef void callback_split_bytes(size_t length, const char* ptr_result_string , void *result) noexcept nogil:
    cdef:
        size_t i
        vector[uint8_t] s
    s.reserve(length)
    for i in range(length):
        s.emplace_back(<uint8_t>ptr_result_string[i])
    (<vector[vector[uint8_t]]*>(result))[0].emplace_back(s)

cdef void callback_find_iter_multiple(size_t index, size_t group, size_t start, size_t end, void* results) noexcept nogil:
    if group==0:
        (<vector[vector[regex_match_multi]]*>results)[0].emplace_back()
    (<vector[vector[regex_match_multi]]*>results)[0].back().emplace_back(regex_match_multi(index, group, start, end))

cdef void callback_find(size_t start, size_t end, void* results) noexcept nogil:
    (<pair[size_t, size_t]*>results)[0].first=start
    (<pair[size_t, size_t]*>results)[0].second=end

cdef:
    str library_path_string = get_or_compile_dll()
    unordered_map[cstring,void*] func_dict = get_c_function_ptr(library_path_string)
    c_get_regex_groups* ptr_get_regex_groups = <c_get_regex_groups*>callback_get_regex_groups
    c_replace_string* ptr_replace_string = <c_replace_string*>callback_replace_string
    c_find_iter* ptr_find_iter = <c_find_iter*>callback_find_iter
    c_split* ptr_split = <c_split*>callback_split
    c_split_bytes* ptr_split_bytes = <c_split_bytes*>callback_split_bytes
    c_find_iter_multiple* ptr_find_iter_multiple = <c_find_iter_multiple*>callback_find_iter_multiple
    c_find* ptr_find = <c_find*>callback_find
    c_replace_string_bytes* ptr_replace_string_bytes = <c_replace_string_bytes*>callback_replace_string_bytes

cdef _convert_to_memview(str v):
    """
    Encode a Python str to an unsigned-char memory-view (UTF-8).

    Parameters
    ----------
    v : str
        The Unicode string to be converted.

    Returns
    -------
    const unsigned char[:]
        A zero-copy memory-view suitable for passing to the Rust layer.

    Raises
    ------
    ValueError
        If v is not an instance of str
    """
    cdef:
        const unsigned char[:] v_view
    if isinstance(v, str):
        v_view = v.encode("utf-8")
    else:
        raise ValueError("Value is not a string")
    return v_view

cdef char ** to_cstring_array(list strings):
    cdef:
        const char *s
        size_t l = len(strings)
        char **ret = <char **>malloc((l + 1) * sizeof(char *))
        Py_ssize_t i

    if not ret:
        raise MemoryError("Buy more memory")

    ret[l] = NULL
    for i in range(l):
        s = strings[i]
        ret[i] = strdup(s)
        if not ret[i]:
            _free_cstring_array(ret)
            raise MemoryError("Buy more memory")
    return ret

cdef void _free_cstring_array(char **arr):
    cdef Py_ssize_t i = 0
    if arr == NULL:
        return
    while arr[i] != NULL:
        free(arr[i])
        i += 1
    free(arr)

@cython.final
cdef class RustRegex:
    """
    Compiled regular-expression object backed by Rust's Regex crate.

    Construction is eager (groups pre-extracted), all subsequent
    operations (match, search, substitution, split, etc.) drop the GIL
    and run inside highly-optimized Rust code, results are collected using C/C++ callback functions

    The API intentionally mirrors Python's re module where possible,
    plus extra helpers for bytes vs. str, keeping-delimiters splits,
    group-aware splits, and multi-pattern search.
    """
    cdef:
        const unsigned char[:] regex_view
        const char* ptr_regex_view
        str regex
        cppmap[size_t,cstring] group_dict
        size_t group_size

    def __init__(self, str regex):
        """
        Compile the regex immediately and cache group meta-information.

        Parameters
        ----------
        regex : str

        Raises
        ------
        ValueError
            When underlying Rust compilation fails.
        """
        self.regex_view=_convert_to_memview(regex)
        self.ptr_regex_view=<const char*>(&(self.regex_view[0]))
        with nogil:
            (<r_get_regex_groups*>func_dict[get_regex_groups])[0](
                self.ptr_regex_view,
                ptr_get_regex_groups,
                &self.group_dict
            )
        if not self.group_dict.size():
            raise ValueError("Error during Regex compilation!")
        self.group_size = self.group_dict.size()
        self.regex = repr(regex)

    def __repr__(self) -> str:
        """
        Formal representation `RustRegex('<pattern>')`.

        Returns
        -------
        str
            The formal pattern representation.
        """
        return f"RustRegex({self.regex})"

    def __str__(self) -> str:
        """
        Return raw regex pattern as `str`.

        Returns
        -------
        str
            The raw pattern string.
        """
        return self.regex

    def sub(self, repl, string, size_t count=0):
        """
        Return *string* with occurrences of the pattern replaced by *repl*.

        repl and string must both be str or both be
        bytes; otherwise a ValueError is raised.

        Parameters
        ----------
        repl : str | bytes
            Replacement text.
        string : str | bytes
            Input text.
        count : int, optional
            Maximum number of substitutions (0 = unlimited).

        Returns
        -------
        str | bytes
            The resulting text.

        Raises
        ------
        ValueError
            if repl is not of type str|bytes and type(repl) != type(string)
        """
        if isinstance(string, str) and isinstance(repl, str):
            return self._sub_str(repl, string, count)
        elif isinstance(string, bytes) and isinstance(repl, bytes):
            return self._sub_bytes(repl, string, count)
        raise ValueError("Only instances of string / string or bytes / bytes allowed")

    def _sub_bytes(self, const unsigned char[:] v_repl, const unsigned char[:] v_st, size_t count=0):
        cdef:
            vector[uint8_t] result_string
            size_t len_v_str = len(v_st)
            size_t len_v_repl = len(v_repl)
        with nogil:
            (<r_replace_string_bytes*>func_dict[replace_string_bytes])[0](
                self.ptr_regex_view,
                <const char*>&v_repl[0],
                len_v_repl,
                <const char*>&v_st[0],
                len_v_str,
                count,
                ptr_replace_string_bytes,
                &result_string
            )
        return bytes(bytearray(result_string))

    def _sub_str(self, str repl, str string, size_t count=0):
        cdef:
            const unsigned char[:] v_repl = _convert_to_memview(repl)
            const unsigned char[:] v_st = _convert_to_memview(string)
            cstring result_string
        with nogil:
            (<r_replace_string*>func_dict[replace_string])[0](
                self.ptr_regex_view,
                <const char*>&v_repl[0],
                <const char*>&v_st[0],
                count,
                ptr_replace_string,
                &result_string
            )
        return result_string.decode("utf-8")

    def is_match(self, string):
        """
        Test whether string matches the pattern at least once.

        Accepts both str and bytes.

        Parameters
        ----------
        string : str | bytes
            Source buffer to search.

        Returns
        -------
        bool
            True if a match is found, False otherwise.

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        if isinstance(string,str):
            return self._is_match_str(string)
        elif isinstance(string, bytes):
            return self._is_match_bytes(string)
        raise ValueError("Only instance of string or bytes allowed")

    def _is_match_str(self, str string):
        cdef:
            const unsigned char[:] v_st = _convert_to_memview(string)
            size_t result
        with nogil:
            result = (<r_is_match*>func_dict[is_match])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
            )
        return bool(result)

    def _is_match_bytes(self, const unsigned char[:] v_st):
        cdef:
            size_t length = len(v_st)
            size_t result
        with nogil:
            result = (<r_is_match_bytes*>func_dict[is_match_bytes])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                length,
            )
        return bool(result)

    def find(self, string, size_t endpos=9223372036854775807):
        """
        Return the position (start, end) and matched text of the first
        match in string (or an empty list if no match is found).

        The call is O(1) for non-matching strings thanks to Rust's
        lazy-DFA implementation.

        Parameters
        ----------
        string : str | bytes
            Source buffer to search.
        endpos : int, optional
            Slice bound for end position — identical to re's convention.

        Returns
        -------
        list[size_t, size_t, str|bytes]
            [start_index, end_index, matched_text]

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        if isinstance(string, str):
            return self._find_str(string, endpos)
        elif isinstance(string, bytes):
            return self._find_bytes(string, endpos)
        raise ValueError("Only instance of string or bytes allowed")

    def _find_bytes(self, const unsigned char[:] v_st, size_t endpos=9223372036854775807):
        cdef:
            pair[size_t, size_t] result
            size_t length = len(v_st)
        with nogil:
            (<r_find_bytes*>func_dict[find_bytes])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                length,
                ptr_find,
                &result,
                endpos,
            )
        if result.second!=0:
            return [result.first, result.second, bytes(v_st[result.first:result.second])]
        return []

    def _find_str(self, str string, size_t endpos=9223372036854775807):
        cdef:
            const unsigned char[:] v_st = _convert_to_memview(string)
            pair[size_t, size_t] result
        with nogil:
            (<r_find*>func_dict[find])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                ptr_find,
                &result,
                endpos,
            )
        if result.second!=0:
            return [result.first, result.second, bytes(v_st[result.first:result.second]).decode("utf-8")]
        return []

    def finditer(self, string, size_t pos=0, size_t endpos=9223372036854775807):
        """
        Alias for :meth:`find_iter`, provided for API familiarity with
        :py:class:`re.Pattern`. All parameters/semantics are identical.

        Parameters
        ----------
        string : str | bytes
            Source buffer to search.
        pos : int, optional
            Slice bound for start position.
        endpos : int, optional
            Slice bound for end position.

        Yields
        ------
        list[list[dict]]
            A list per overall match, each containing dicts of match metadata.

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        return self.find_iter(string, pos, endpos)

    def find_iter(self, string, size_t pos=0, size_t endpos=9223372036854775807):
        """
        Yield all matches in string as a list of dictionaries. The first item in the list corresponds to group 0 (whole match)
            {
                "start":  …,          # BYTE OFFSET! MAY BE DIFFERENT FROM THE ACTUAL OFFSET (if data is passed as a instance of str)
                "end":    …,          # BYTE OFFSET! MAY BE DIFFERENT FROM THE ACTUAL OFFSET (if data is passed as a instance of str)
                "length": …,          # BYTE LENGTH! MAY BE DIFFERENT FROM THE ACTUAL LENGTH (if data is passed as a instance of str)
                "group":  …,          # numeric group id
                "groupname": …,       # '' if no name
                "match":  …           # str | bytes snippet
            }
        Works for both bytes and str input.


        Parameters
        ----------
        string : str | bytes
            Source buffer to search.
        pos : int, optional
            Slice bound for start position.
        endpos : int, optional
            Slice bound for end position.

        Yields
        ------
        list[list[dict]]
            A list per overall match, each containing dicts of match metadata.

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        if isinstance(string, str):
            yield from self._find_iter_str(string, pos, endpos)
        elif isinstance(string, bytes):
            yield from self._find_iter_bytes(string, pos, endpos)
        else:
            raise ValueError("Only instance of string or bytes allowed")

    def _find_iter_bytes(self, const unsigned char[:] v_st, size_t pos=0, size_t endpos=9223372036854775807):
        cdef:
            vector[vector[regex_match]] results
            Py_ssize_t i,j
            dict[size_t,str] group_dict = {k:v.decode("utf-8") for k,v in dict(self.group_dict).items()}
            size_t start
            size_t end
            list[dict[str,object]] result_list = []
            size_t length = len(v_st)
        if pos >= len(v_st) or pos < 0:
            raise IndexError("pos is out of bounds!")
        with nogil:
            (<r_find_iter_bytes*>func_dict[find_iter_bytes])[0](
                self.ptr_regex_view,
                <const char*>&v_st[pos],
                length,
                ptr_find_iter,
                &results,
                endpos
            )
        for i in range(<Py_ssize_t>results.size()):
            for j in range(<Py_ssize_t>results[i].size()):
                if results[i][j].g==0:
                    result_list = []
                start=pos+results[i][j].s
                end=pos+results[i][j].e
                result_list.append(
                    {
                        "start":start,
                        "end": end,
                        "length": end-start,
                        "group": results[i][j].g,
                        "groupname": group_dict[results[i][j].g],
                        "match": bytes(v_st[start:end])
                    }
                )
            yield result_list

    def _find_iter_str(self, str string, size_t pos=0, size_t endpos=9223372036854775807):
        cdef:
            const unsigned char[:] v_st = _convert_to_memview(string)
            vector[vector[regex_match]] results
            Py_ssize_t i,j
            dict[size_t,str] group_dict = {k:v.decode("utf-8") for k,v in dict(self.group_dict).items()}
            size_t start
            size_t end
            list[dict[str,object]] result_list = []
        if pos >= len(v_st) or pos < 0:
            raise IndexError("pos is out of bounds!")
        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[pos],
                ptr_find_iter,
                &results,
                endpos
            )
        for i in range(<Py_ssize_t>results.size()):
            for j in range(<Py_ssize_t>results[i].size()):
                if results[i][j].g==0:
                    result_list = []
                start=pos+results[i][j].s
                end=pos+results[i][j].e
                result_list.append(
                    {
                        "start":start,
                        "end": end,
                        "length": end-start,
                        "group": results[i][j].g,
                        "groupname": group_dict[results[i][j].g],
                        "match": bytes(v_st[start:end]).decode("utf-8")
                    }
                )
            yield result_list

    def findall(self, string, size_t pos=0, size_t endpos=9223372036854775807):
        """
        Alias for :meth:`find_all`, provided for API familiarity with
        :py:class:`re.Pattern`. All parameters/semantics are identical.

        Parameters
        ----------
        string : str | bytes
            Source buffer to search.
        pos : int, optional
            Slice bound for start position.
        endpos : int, optional
            Slice bound for end position.

        Returns
        -------
        list[str] | list[bytes]
            All full matches in order of appearance.

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        return self.find_all(string, pos, endpos)

    def find_all(self, string, size_t pos=0, size_t endpos=9223372036854775807):
        """
        Return all non-overlapping occurrences of group 0 (the full match) in string.

        Parameters
        ----------
        string : str | bytes
            Source buffer to search.
        pos : int, optional
            Slice bound for start position.
        endpos : int, optional
            Slice bound for end position.

        Returns
        -------
        list[str] | list[bytes]
            All full matches in order of appearance.

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        if isinstance(string, str):
            return self._find_all_str(string, pos, endpos)
        elif isinstance(string, bytes):
            return self._find_all_bytes(string, pos, endpos)
        raise ValueError("Only instance of string or bytes allowed")

    def _find_all_str(self, str string, size_t pos=0, size_t endpos=9223372036854775807):
        """
        Internal UTF-8 implementation backing :meth:find_all.

        The function runs entirely without the GIL and returns a
        *Python* list of decoded substrings on completion.
        """
        cdef:
            const unsigned char[:] v_st = _convert_to_memview(string)
            vector[vector[regex_match]] results
            Py_ssize_t i,j
            list[str] result_list = []
        if pos >= len(v_st) or pos < 0:
            raise IndexError("pos is out of bounds!")
        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[pos],
                ptr_find_iter,
                &results,
                endpos
            )
        for i in range(<Py_ssize_t>results.size()):
            for j in range(<Py_ssize_t>results[i].size()):
                if results[i][j].g!=0:
                    continue
                result_list.append(
                    bytes(v_st[pos+results[i][j].s:pos+results[i][j].e]).decode("utf-8")
                )
        return result_list

    def _find_all_bytes(self, const unsigned char[:] v_st, size_t pos=0, size_t endpos=9223372036854775807):
        """
        Byte-level twin of :meth:_find_all_str.  Keeps results as raw
        bytes objects.
        """
        cdef:
            vector[vector[regex_match]] results
            Py_ssize_t i,j
            list[bytes] result_list = []
        if pos >= len(v_st) or pos < 0:
            raise IndexError("pos is out of bounds!")
        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[pos],
                ptr_find_iter,
                &results,
                endpos
            )
        for i in range(<Py_ssize_t>results.size()):
            for j in range(<Py_ssize_t>results[i].size()):
                if results[i][j].g!=0:
                    continue
                result_list.append(
                    bytes(v_st[pos+results[i][j].s:pos+results[i][j].e])
                )
        return result_list

    def find_all_groups(self, string, size_t pos=0, size_t endpos=9223372036854775807):
        """
        Gather only the text captured by named/numbered groups for
        every match.

        Each outer list element corresponds to one overall match; the
        inner list contains the capture content of group 1..N (group 0,
        the whole match, is omitted).

        Parameters
        ----------
        string : str | bytes
            Source buffer to search.
        pos, endpos : int, optional

        Returns
        -------
        list[list[str]] | list[list[bytes]]
            Nested list mirroring the input type.

        Raises
        ------
        ValueError
            if string is not of type bytes|str
        """
        if isinstance(string, str):
            return self._find_all_groups_str(string, pos, endpos)
        elif isinstance(string, bytes):
            return self._find_all_groups_bytes(string, pos, endpos)
        raise ValueError("Only instance of string or bytes allowed")

    def _find_all_groups_str(self, str string, size_t pos=0, size_t endpos=9223372036854775807):
        cdef:
            const unsigned char[:] v_st = _convert_to_memview(string)
            vector[vector[regex_match]] results
            Py_ssize_t i,j
            list[list[str]] result_list = []
            list[str] sub_result_list = []
            Py_ssize_t len_groups = self.group_size-1
        if pos >= len(v_st) or pos < 0:
            raise IndexError("pos is out of bounds!")
        if len_groups <= 0:
            raise ValueError("No capture groups present!")
        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[pos],
                ptr_find_iter,
                &results,
                endpos
            )
        for i in range(<Py_ssize_t>results.size()):
            sub_result_list = [""] * len_groups
            for j in range(<Py_ssize_t>results[i].size()):
                if results[i][j].g==0:
                    continue
                sub_result_list[results[i][j].g-1] = bytes(v_st[pos+results[i][j].s:pos+results[i][j].e]).decode("utf-8")
            result_list.append(sub_result_list)
        return result_list

    def _find_all_groups_bytes(self, const unsigned char[:] v_st, size_t pos=0, size_t endpos=9223372036854775807):
        cdef:
            vector[vector[regex_match]] results
            Py_ssize_t i,j
            list[list[bytes]] result_list = []
            list[bytes] sub_result_list = []
            Py_ssize_t len_groups = self.group_size-1
        if pos >= len(v_st) or pos < 0:
            raise IndexError("pos is out of bounds!")
        if len_groups <= 0:
            raise ValueError("No capture groups present!")
        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[pos],
                ptr_find_iter,
                &results,
                endpos
            )
        for i in range(<Py_ssize_t>results.size()):
            sub_result_list = [b""] * len_groups
            for j in range(<Py_ssize_t>results[i].size()):
                if results[i][j].g==0:
                    continue
                sub_result_list[results[i][j].g-1] = bytes(v_st[pos+results[i][j].s:pos+results[i][j].e])
            result_list.append(sub_result_list)
        return result_list

    def split(self, string, size_t maxsplit=9223372036854775807):
        """
        Split string on pattern occurrences (same semantics as
        :py:meth:re.Pattern.split).  Delimiters are discarded
        (even when in capture groups).

        Parameters
        ----------
        string : str | bytes
            Source buffer to split.
        maxsplit : int, optional
            Maximum number of splits

        Returns
        -------
        list[str] | list[bytes]
            Substrings between delimiters.

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        if isinstance(string, str):
            return self._split_str(string, maxsplit)
        elif isinstance(string, bytes):
            return self._split_bytes(string, maxsplit)
        raise ValueError("Only instance of string or bytes allowed")

    def _split_str(self, str string, size_t maxsplit):
        cdef:
            const unsigned char[:] v_st = _convert_to_memview(string)
            vector[cstring] results
            list[str] result_list=[]
            Py_ssize_t i
            size_t msplit=0 if maxsplit==9223372036854775807 else maxsplit+1

        with nogil:
            (<r_split*>func_dict[split])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                msplit,
                ptr_split,
                &results
            )
        for i in range(<Py_ssize_t>(results.size())):
            result_list.append(results[i].decode("utf-8"))
        return result_list

    def _split_bytes(self, const unsigned char[:] v_st, size_t maxsplit):
        cdef:
            vector[vector[uint8_t]] results
            size_t len_haystack=len(v_st)
            size_t msplit=0 if maxsplit==9223372036854775807 else maxsplit+1

        with nogil:
            (<r_split_bytes*>func_dict[split_bytes])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                len_haystack,
                msplit,
                ptr_split_bytes,
                &results
            )
        return [bytes(bytearray(q)) for q in results]

    def split_keep(self, string, size_t maxsplit=9223372036854775807):
        """
        Split string on pattern occurrences but keeps the full delimiter itself
        as separate list elements.

        Parameters
        ----------
        string : str | bytes
            Source buffer to split.
        maxsplit : int, optional
            Maximum number of splits

        Returns
        -------
        list[str] | list[bytes]
            Substrings including delimiters.

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        if isinstance(string, str):
            return self._split_keep_str(string, maxsplit)
        elif isinstance(string, bytes):
            return self._split_keep_bytes(string, maxsplit)
        raise ValueError("Only instance of string or bytes allowed")

    def _split_keep_bytes(self, const unsigned char[:] v_st, size_t maxsplit=9223372036854775807):
        cdef:
            vector[Py_ssize_t] split_list = [0]
            list result_list=[]
            size_t len_string = len(v_st)
            size_t endpos=9223372036854775807
            vector[vector[regex_match]] results
            bytes tmpstring
            size_t splitcount=0

        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                ptr_find_iter,
                &results,
                endpos
            )
        if results.empty() or maxsplit==0:
            return [bytes(v_st)]
        for i in range(<Py_ssize_t>(results.size())):
            split_list.emplace_back(results[i][0].s)
            split_list.emplace_back(results[i][0].e)
            splitcount+=1
            if splitcount>=maxsplit:
                break
        if split_list[0]==split_list[1]:
            split_list.erase(split_list.begin())
        split_list.emplace_back(split_list.back())
        split_list.emplace_back(len_string)
        for i in range((<Py_ssize_t>(split_list.size()-1))):
            tmpstring=bytes(v_st[split_list[i]: split_list[i + 1]])
            if not tmpstring:
                continue
            result_list.append(tmpstring)
        return result_list

    def _split_keep_str(self, object string, size_t maxsplit=9223372036854775807):
        cdef:
            const unsigned char[:] v_st = _convert_to_memview(string)
            vector[Py_ssize_t] split_list = [0]
            list result_list=[]
            size_t len_string = len(v_st)
            size_t endpos=9223372036854775807
            vector[vector[regex_match]] results
            str tmpstring
            size_t splitcount=0

        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                ptr_find_iter,
                &results,
                endpos
            )
        if results.empty() or maxsplit==0:
            return [string]
        for i in range(<Py_ssize_t>(results.size())):
            split_list.emplace_back(results[i][0].s)
            split_list.emplace_back(results[i][0].e)
            splitcount+=1
            if splitcount>=maxsplit:
                break
        if split_list[0]==split_list[1]:
            split_list.erase(split_list.begin())
        split_list.emplace_back(split_list.back())
        split_list.emplace_back(len_string)
        for i in range((<Py_ssize_t>(split_list.size()-1))):
            tmpstring=bytes(v_st[split_list[i]: split_list[i + 1]]).decode("utf-8")
            if not tmpstring:
                continue
            result_list.append(tmpstring)
        return result_list

    def split_keep_groups(self, string, size_t maxsplit=9223372036854775807):
        """
        Similar to :meth:split_keep but keeps only the content of capturing groups
        within the delimiters instead of the full delimiter itself.

        Parameters
        ----------
        string : str | bytes
            Source buffer to split.
        maxsplit : int, optional
            Maximum number of splits.

        Returns
        -------
        list[str] | list[bytes]
            A list of substrings and captured group bytes/strings.

        Raises
        ------
        ValueError
            If string is not of type bytes|str.
        """
        if isinstance(string, str):
            return self._split_keep_groups_str(string, maxsplit)
        elif isinstance(string, bytes):
            return self._split_keep_groups_bytes(string, maxsplit)
        raise ValueError("Only instance of string or bytes allowed")

    def _split_keep_groups_bytes(self, const unsigned char[:] v_st, size_t maxsplit=9223372036854775807):
        cdef:
            vector[Py_ssize_t] split_list = [0]
            list result_list=[]
            size_t len_string = len(v_st)
            size_t endpos=9223372036854775807
            vector[vector[regex_match]] results
            bytes tmpstring
            size_t splitcount=0
            bint gotmax=False

        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                ptr_find_iter,
                &results,
                endpos
            )
        if results.empty() or maxsplit==0:
            return [bytes(v_st)]
        for i in range(<Py_ssize_t>(results.size())):
            if gotmax:
                break
            for j in range(<Py_ssize_t>(results[i].size())):
                if not results[i][j].g:
                    continue
                split_list.emplace_back(results[i][j].s)
                split_list.emplace_back(results[i][j].e)
                splitcount+=1
                if splitcount>=maxsplit:
                    gotmax=True
                    break
        if split_list[0]==split_list[1]:
            split_list.erase(split_list.begin())
        split_list.emplace_back(split_list.back())
        split_list.emplace_back(len_string)
        for i in range((<Py_ssize_t>(split_list.size()-1))):
            tmpstring=bytes(v_st[split_list[i]: split_list[i + 1]])
            if not tmpstring:
                continue
            result_list.append(tmpstring)
        return result_list

    def _split_keep_groups_str(self, object string, size_t maxsplit=9223372036854775807):
        cdef:
            const unsigned char[:] v_st = _convert_to_memview(string)
            vector[Py_ssize_t] split_list = [0]
            list result_list=[]
            size_t len_string = len(v_st)
            size_t endpos=9223372036854775807
            vector[vector[regex_match]] results
            str tmpstring
            size_t splitcount=0
            bint gotmax=False

        with nogil:
            (<r_find_iter*>func_dict[find_iter])[0](
                self.ptr_regex_view,
                <const char*>&v_st[0],
                ptr_find_iter,
                &results,
                endpos
            )
        if results.empty() or maxsplit==0:
            return [string]
        for i in range(<Py_ssize_t>(results.size())):
            if gotmax:
                break
            for j in range(<Py_ssize_t>(results[i].size())):
                if not results[i][j].g:
                    continue
                split_list.emplace_back(results[i][j].s)
                split_list.emplace_back(results[i][j].e)
                splitcount+=1
                if splitcount>=maxsplit:
                    gotmax=True
                    break
        if split_list[0]==split_list[1]:
            split_list.erase(split_list.begin())
        split_list.emplace_back(split_list.back())
        split_list.emplace_back(len_string)
        for i in range((<Py_ssize_t>(split_list.size()-1))):
            tmpstring=bytes(v_st[split_list[i]: split_list[i + 1]]).decode("utf-8")
            if not tmpstring:
                continue
            result_list.append(tmpstring)
        return result_list

    @classmethod
    def from_wordlist(cls, list[str] wordlist,
        str add_before="",
        str add_after="",
        bint boundary_right=True,
        bint boundary_left=True,
        bint capture=False,
        bint match_whole_line=False,
        ):
        """
        Shortcut constructor that builds a single pattern matching any
        word in *wordlist* (internally via :class:`Trie`).

        Parameters
        ----------
        wordlist : list[str]
            Words to include in the pattern.
        add_before : str, optional
            Prefix to add before each word.
        add_after : str, optional
            Suffix to add after each word.
        boundary_left : bool, optional
            Enforce left boundary.
        boundary_right : bool, optional
            Enforce right boundary.
        capture : bool, optional
            Enable capture groups.
        match_whole_line : bool, optional
            Match the entire line.

        Returns
        -------
        RustRegex
            Compiled pattern matching any word in *wordlist*.
        """
        cdef:
            str regexstring=Trie().regex_from_words(wordlist).compile(
            add_before=add_before,
            add_after=add_after,
            boundary_right=boundary_right,
            boundary_right=boundary_right,
            boundary_left=boundary_left,
            capture=capture,
            match_whole_line=match_whole_line,
        )
        return cls(regexstring)


    @staticmethod
    def find_regex_multi(list[str] regexes, haystack):
        """
        Search *haystack* with **multiple** patterns in a *single* pass.

        Parameters
        ----------
        regexes : list[str]
            Collection of raw regex patterns to be compiled inside Rust.
        haystack : str | bytes
            Input buffer to scan.

        Yields
        ------
        list[dict]
            One list per overall match. Each dict contains metadata plus
            an additional key "regex" with the index of the pattern.

        Raises
        ------
        ValueError
            If haystack is not of type bytes|str.
        """
        if isinstance(haystack, str):
            yield from __class__._find_regex_multi_str(regexes, haystack)
        elif isinstance(haystack, bytes):
            yield from __class__._find_regex_multi_bytes(regexes, haystack)
        else:
            raise ValueError("haystack must be either bytes or string")

    @staticmethod
    def _find_regex_multi_str(list[str] regexes, str haystack):
        cdef:
            size_t count = len(regexes)
            char ** malloc_strings = to_cstring_array(regexes)
            const unsigned char[:] haystack_view=_convert_to_memview(haystack)
            vector[vector[regex_match_multi]] results
            list[dict[str,object]] result_list = []
            Py_ssize_t i, j

        with nogil:
            (<r_find_iter_multiple*>func_dict[find_iter_multiple])[0](
                <const char**>malloc_strings,
                count,
                <const char*>&haystack_view[0],
                ptr_find_iter_multiple,
                &results
            )
        _free_cstring_array(malloc_strings)
        for i in range(<Py_ssize_t>results.size()):
            for j in range(<Py_ssize_t>results[i].size()):
                if results[i][j].g==0:
                    result_list = []
                result_list.append(
                    {
                        "regex": results[i][j].i,
                        "start": results[i][j].s,
                        "end": results[i][j].e,
                        "length": results[i][j].e-results[i][j].s,
                        "group": results[i][j].g,
                        "match": bytes(haystack_view[results[i][j].s:results[i][j].e]).decode("utf-8")
                    }
                )
            yield result_list

    @staticmethod
    def _find_regex_multi_bytes(list[str] regexes, const unsigned char[:] haystack):
        cdef:
            size_t count = len(regexes)
            char ** malloc_strings = to_cstring_array(regexes)
            vector[vector[regex_match_multi]] results
            list[dict[str,object]] result_list = []
            Py_ssize_t i, j
            size_t len_haystack=len(haystack)

        with nogil:
            (<r_find_iter_multiple_bytes*>func_dict[find_iter_multiple_bytes])[0](
                <const char**>malloc_strings,
                count,
                <const char*>&haystack[0],
                len_haystack,
                ptr_find_iter_multiple,
                &results
            )
        _free_cstring_array(malloc_strings)
        for i in range(<Py_ssize_t>results.size()):
            for j in range(<Py_ssize_t>results[i].size()):
                if results[i][j].g==0:
                    result_list = []
                result_list.append(
                    {
                        "regex": results[i][j].i,
                        "start": results[i][j].s,
                        "end": results[i][j].e,
                        "length": results[i][j].e-results[i][j].s,
                        "group": results[i][j].g,
                        "match": bytes(haystack[results[i][j].s:results[i][j].e]),
                    }
                )
            yield result_list

    @staticmethod
    def clean_regex_cache():
        """
        Flush the global Rust-side cache of compiled patterns.

        Use this after creating and discarding thousands of RustRegex
        instances in a long-running process to reclaim native memory.
        """
        with nogil:
            (<r_clean_regex_cache*>func_dict[clean_regex_cache])[0]()

    @staticmethod
    def set_regex_size_limit(size_t limit=1024*1024*1024):
        """
        Changes the default size for StrRegexBuilder / BytesRegexBuilder
        Defaults to 1024*1024*1024
        """
        with nogil:
            (<r_set_regex_size_limit*>func_dict[set_regex_size_limit])[0](limit)
