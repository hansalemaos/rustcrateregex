import cython
cimport cython
import os
import ctypes
from libcpp.vector cimport vector
from libcpp.utility cimport pair
import shutil
from libc.stdint cimport *

ctypedef void (*callback_function)(size_t, size_t) noexcept nogil
ctypedef void (*pure_rustc_function)(const char*, const char*, callback_function*) noexcept nogil
ctypedef pair[size_t,size_t] size_t_pair

cdef:
    vector[size_t_pair] result_vector
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
    for file in _possible_files:
        if os.path.exists(file):
            return file
    return None

cdef get_or_compile_dll():
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

cdef pure_rustc_function* get_c_function_ptr(str dllpathstr):
    cta = ctypes.cdll.LoadLibrary(dllpathstr)
    _func_cache.append(cta)
    return (<pure_rustc_function*><size_t>ctypes.addressof(cta.for_each_match))

cdef void callback_function_cpp(size_t start, size_t end) noexcept nogil:
    result_vector.emplace_back(size_t_pair(start,end))

cdef:
    str library_path_string = get_or_compile_dll()
    pure_rustc_function* fu = get_c_function_ptr(library_path_string)
    callback_function* ptr_callback_function = <callback_function*>callback_function_cpp

cpdef rust_regex(const unsigned char[:] regex, const unsigned char[:] string):
    cdef:
        const char* r = <const char*>(&(regex[0]))
        const char* s = <const char*>(&(string[0]))
        list[(uint64_t,uint64_t)] result_list
    with nogil:
        fu[0](r,s,ptr_callback_function)
    result_list=result_vector
    result_vector.clear()
    return result_list

