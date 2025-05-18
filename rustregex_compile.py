from Cython.Compiler import Options
from setuptools import Extension, setup
from Cython.Build import cythonize
import sys
import platform

iswindows = "win" in platform.platform().lower()
name = "rustregex"

Options.docstrings = False
Options.embed_pos_in_docstring = False
Options.generate_cleanup_code = False
Options.clear_to_none = True
Options.annotate = True
Options.fast_fail = False
Options.warning_errors = False
Options.error_on_unknown_names = True
Options.error_on_uninitialized = True
Options.convert_range = True
Options.cache_builtins = True
Options.gcc_branch_hints = True
Options.lookup_module_cpdef = False
Options.embed = False
Options.cimport_from_pyx = False
Options.buffer_max_dims = 8


Options.closure_freelist_size = 8

configdict = {
    "py_limited_api": False,
    "name": name,
    "sources": [
        name + ".pyx",
    ],
    "include_dirs": [],
    "define_macros": [],
    "undef_macros": [],
    "library_dirs": [],
    "libraries": [],
    "runtime_library_dirs": [],
    "extra_objects": [],
    "extra_compile_args": [
    ]
    if iswindows
    else [
        "-march=native",
        "-mtune=native",
    ],
    "extra_link_args": [],
    "export_symbols": [],
    "swig_opts": [],
    "depends": [],
    "language": "c++",
    "optional": None,
}
compiler_directives = {
    "binding": True,
    "boundscheck": False,
    "wraparound": False,
    "initializedcheck": False,
    "nonecheck": False,
    "overflowcheck": False,
    "overflowcheck.fold": False,
    "embedsignature": False,
    "embedsignature.format": "c",
    "cdivision": True,
    "cdivision_warnings": False,
    "cpow": True,
    "always_allow_keywords": False,
    "c_api_binop_methods": False,
    "profile": False,
    "linetrace": False,
    "infer_types": True,
    "language_level": 3,
    "c_string_type": "bytes",
    "c_string_encoding": "ascii",
    "type_version_tag": False,
    "unraisable_tracebacks": True,
    "iterable_coroutine": True,
    "annotation_typing": True,
    "emit_code_comments": True,
    "cpp_locals": False,
    "legacy_implicit_noexcept": False,
    "optimize.use_switch": True,
    "optimize.unpack_method_calls": True,
    "warn.undeclared": True,
    "warn.unreachable": True,
    "warn.maybe_uninitialized": True,
    "warn.unused": True,
    "warn.unused_arg": True,
    "warn.unused_result": True,
    "warn.multiple_declarators": True,
    "show_performance_hints": True,
}
compdi = configdict
clidict = compiler_directives

ext_modules = Extension(**configdict)

setup(
    name=name,
    ext_modules=cythonize(ext_modules, compiler_directives=compiler_directives),
)
sys.exit(0)
