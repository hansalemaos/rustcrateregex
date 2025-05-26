use once_cell::sync::Lazy;
use regex::bytes::{
    Regex as BytesRegex, RegexBuilder as BytesRegexBuilder, RegexSet as BytesRegexSet,
    RegexSetBuilder as BytesRegexSetBuilder,
};
use regex::{
    Regex as StrRegex, RegexBuilder as StrRegexBuilder, RegexSet as StrRegexSet,
    RegexSetBuilder as StrRegexSetBuilder,
};
use std::collections::HashMap;
use std::ffi::{c_void, CStr};
use std::os::raw::c_char;
use std::ptr;
use std::slice;
use std::sync::Mutex;

static SIZE_LIMIT: Lazy<Mutex<usize>> = Lazy::new(|| Mutex::new(1024 * 1024 * 1024));

#[no_mangle]
pub extern "C" fn set_regex_size_limit(limit: usize) {
    if let Ok(mut l) = SIZE_LIMIT.lock() {
        *l = limit;
    }
}

static REGEX_CACHE_STR: Lazy<Mutex<HashMap<String, StrRegex>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static REGEX_CACHE_BYTES: Lazy<Mutex<HashMap<String, BytesRegex>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static REGEX_SET_CACHE_STR: Lazy<Mutex<HashMap<Vec<String>, StrRegexSet>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static REGEX_SET_CACHE_BYTES: Lazy<Mutex<HashMap<Vec<String>, BytesRegexSet>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn get_or_compile_str_regex(pattern: &str) -> Option<StrRegex> {
    let mut cache = REGEX_CACHE_STR.lock().ok()?;
    if let Some(re) = cache.get(pattern) {
        return Some(re.clone());
    }
    let limit = *SIZE_LIMIT.lock().ok()?;
    let compiled = StrRegexBuilder::new(pattern)
        .size_limit(limit)
        .build()
        .ok()?;
    cache.insert(pattern.to_string(), compiled.clone());
    Some(compiled)
}

fn get_or_compile_bytes_regex(pattern: &str) -> Option<BytesRegex> {
    let mut cache = REGEX_CACHE_BYTES.lock().ok()?;
    if let Some(re) = cache.get(pattern) {
        return Some(re.clone());
    }
    let limit = *SIZE_LIMIT.lock().ok()?;
    let compiled = BytesRegexBuilder::new(pattern)
        .size_limit(limit)
        .build()
        .ok()?;
    cache.insert(pattern.to_string(), compiled.clone());
    Some(compiled)
}

fn get_or_compile_str_regex_set(patterns: &[&str]) -> Option<StrRegexSet> {
    let key: Vec<String> = patterns.iter().map(|s| s.to_string()).collect();
    let mut cache = REGEX_SET_CACHE_STR.lock().ok()?;
    if let Some(set) = cache.get(&key) {
        return Some(set.clone());
    }
    let limit = *SIZE_LIMIT.lock().ok()?;
    let compiled = StrRegexSetBuilder::new(patterns)
        .size_limit(limit)
        .build()
        .ok()?;
    cache.insert(key, compiled.clone());
    Some(compiled)
}

fn get_or_compile_bytes_regex_set(patterns: &[&str]) -> Option<BytesRegexSet> {
    let key: Vec<String> = patterns.iter().map(|s| s.to_string()).collect();
    let mut cache = REGEX_SET_CACHE_BYTES.lock().ok()?;
    if let Some(set) = cache.get(&key) {
        return Some(set.clone());
    }
    let limit = *SIZE_LIMIT.lock().ok()?;
    let compiled = BytesRegexSetBuilder::new(patterns)
        .size_limit(limit)
        .build()
        .ok()?;
    cache.insert(key, compiled.clone());
    Some(compiled)
}

#[no_mangle]
pub unsafe extern "C" fn get_regex_groups(
    pattern: *const c_char,
    callback: Option<
        extern "C" fn(group: usize, name: *const c_char, result: *mut c_void, length: usize),
    >,
    v: *mut c_void,
) {
    if pattern.is_null() || callback.is_none() || v.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let pattern_str = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };

    let re = match get_or_compile_str_regex(pattern_str) {
        Some(r) => r,
        None => {
            eprintln!("Invalid pattern!");
            return;
        }
    };

    let callbackfu = callback.unwrap();

    for (i, name_opt) in re.capture_names().enumerate() {
        match name_opt {
            Some(name) => {
                let c_ptr: *const c_char = name.as_ptr() as *const c_char;
                callbackfu(i, c_ptr, v, name.len());
            }
            None => {
                callbackfu(i, ptr::null(), v, 0);
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn replace_string(
    pattern: *const c_char,
    replace_pattern: *const c_char,
    haystack: *const c_char,
    count: usize,
    callback: Option<
        extern "C" fn(length: usize, ptr_result_string: *const c_char, result: *mut c_void),
    >,
    v: *mut c_void,
) {
    if pattern.is_null()
        || haystack.is_null()
        || replace_pattern.is_null()
        || callback.is_none()
        || v.is_null()
    {
        eprintln!("Nullptr passed!");
        return;
    }

    let replace_pattern_str = match CStr::from_ptr(replace_pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };

    let pattern_str = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };

    let re = match get_or_compile_str_regex(pattern_str) {
        Some(r) => r,
        None => {
            eprintln!("Invalid pattern!");
            return;
        }
    };
    let text_str = match CStr::from_ptr(haystack).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };
    let callbackfu = callback.unwrap();
    let replaced = re.replacen(text_str, count, replace_pattern_str);
    let c_ptr: *const c_char = replaced.as_ptr() as *const c_char;

    callbackfu(replaced.len(), c_ptr, v);
}

#[no_mangle]
pub unsafe extern "C" fn is_match(pattern: *const c_char, haystack: *const c_char) -> usize {
    if pattern.is_null() || haystack.is_null() {
        eprintln!("Nullptr passed!");
        return 0;
    }

    let pattern_str = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return 0;
        }
    };

    let re = match get_or_compile_str_regex(pattern_str) {
        Some(r) => r,
        None => {
            eprintln!("invalid pattern");
            return 0;
        }
    };

    let text_str = match CStr::from_ptr(haystack).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return 0;
        }
    };

    re.is_match(text_str) as usize
}

#[no_mangle]
pub unsafe extern "C" fn find_iter(
    pattern: *const c_char,
    haystack: *const c_char,
    callback: Option<extern "C" fn(group: usize, start: usize, end: usize, results: *mut c_void)>,
    v: *mut c_void,
    endpos: usize,
) {
    if pattern.is_null() || haystack.is_null() || callback.is_none() || v.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let pattern_str = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };

    let re = match get_or_compile_str_regex(pattern_str) {
        Some(r) => r,
        None => {
            eprintln!("Invalid pattern!");
            return;
        }
    };
    let text_str = match CStr::from_ptr(haystack).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };

    let callbackfu = callback.unwrap();

    for caps in re.captures_iter(text_str) {
        for i in 0..caps.len() {
            if let Some(group) = caps.get(i) {
                if group.end() > endpos {
                    return;
                }
                callbackfu(i, group.start(), group.end(), v);
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn split(
    pattern: *const c_char,
    haystack: *const c_char,
    maxsplit: usize,
    callback: Option<extern "C" fn(length: usize, haystack: *const c_char, results: *mut c_void)>,
    v: *mut c_void,
) {
    if pattern.is_null() || haystack.is_null() || callback.is_none() || v.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let pattern_str = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };

    let re = match get_or_compile_str_regex(pattern_str) {
        Some(r) => r,
        None => {
            eprintln!("Invalid pattern!");
            return;
        }
    };
    let text_str = match CStr::from_ptr(haystack).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };

    let callbackfu = callback.unwrap();

    if maxsplit == 0 {
        for caps in re.split(text_str) {
            let c_ptr: *const c_char = caps.as_ptr() as *const c_char;
            callbackfu(caps.len(), c_ptr, v);
        }
    } else {
        for caps in re.splitn(text_str, maxsplit) {
            let c_ptr: *const c_char = caps.as_ptr() as *const c_char;
            callbackfu(caps.len(), c_ptr, v);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn find_iter_multiple(
    patterns: *const *const c_char,
    pattern_count: usize,
    haystack: *const c_char,
    callback: Option<
        extern "C" fn(
            pattern_index: usize,
            group: usize,
            start: usize,
            end: usize,
            results: *mut c_void,
        ),
    >,
    v: *mut c_void,
) {
    if patterns.is_null() || haystack.is_null() || callback.is_none() || v.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let mut rust_patterns = Vec::with_capacity(pattern_count);
    for i in 0..pattern_count {
        let ptr = *patterns.add(i);
        if ptr.is_null() {
            eprintln!("Nullptr passed!");
            return;
        }
        let c_str = match CStr::from_ptr(ptr).to_str() {
            Ok(s) => s,
            Err(_) => {
                eprintln!("ptr→str error");
                return;
            }
        };
        rust_patterns.push(c_str);
    }

    let hay = match CStr::from_ptr(haystack).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("ptr→str error");
            return;
        }
    };

    let set = match get_or_compile_str_regex_set(&rust_patterns) {
        Some(s) => s,
        None => {
            eprintln!("Invalid pattern!");
            return;
        }
    };

    let regexes: Vec<StrRegex> = rust_patterns
        .iter()
        .map(|p| get_or_compile_str_regex(p).unwrap())
        .collect();
    let callbackfu = callback.unwrap();

    for index in set.matches(hay).into_iter() {
        for caps in regexes[index].captures_iter(hay) {
            for i in 0..caps.len() {
                if let Some(group) = caps.get(i) {
                    callbackfu(index, i, group.start(), group.end(), v);
                }
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn find(
    pattern: *const c_char,
    haystack: *const c_char,
    callback: Option<extern "C" fn(start: usize, end: usize, user: *mut c_void)>,
    user: *mut c_void,
    endpos: usize,
) {
    if pattern.is_null() || haystack.is_null() || callback.is_none() || user.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let pat = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("Error pattern ptr→str");
            return;
        }
    };

    let re = match get_or_compile_str_regex(pat) {
        Some(r) => r,
        None => {
            eprintln!("Invalid pattern!");
            return;
        }
    };

    let text = match CStr::from_ptr(haystack).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("Error haystack ptr→str");
            return;
        }
    };

    if let Some(mat) = re.find(text) {
        if mat.end() > endpos {
            return;
        }
        let cb = callback.unwrap();
        cb(mat.start(), mat.end(), user);
    }
}

#[no_mangle]
pub unsafe extern "C" fn find_iter_multiple_bytes(
    patterns: *const *const c_char,
    pattern_count: usize,
    haystack: *const u8,
    haystack_len: usize,
    callback: Option<
        extern "C" fn(
            pattern_index: usize,
            group: usize,
            start: usize,
            end: usize,
            results: *mut c_void,
        ),
    >,
    v: *mut c_void,
) {
    if patterns.is_null() || haystack.is_null() || callback.is_none() || v.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let mut rust_patterns = Vec::with_capacity(pattern_count);
    for i in 0..pattern_count {
        let ptr = *patterns.add(i);
        if ptr.is_null() {
            eprintln!("Null pattern pointer!");
            return;
        }
        let c_str = match CStr::from_ptr(ptr).to_str() {
            Ok(s) => s,
            Err(_) => {
                eprintln!("ptr→str error");
                return;
            }
        };
        rust_patterns.push(c_str);
    }

    let hay = slice::from_raw_parts(haystack, haystack_len);
    let set = match get_or_compile_bytes_regex_set(&rust_patterns) {
        Some(s) => s,
        None => {
            eprintln!("Invalid pattern set!");
            return;
        }
    };

    let regexes: Vec<BytesRegex> = rust_patterns
        .iter()
        .filter_map(|p| get_or_compile_bytes_regex(p))
        .collect();

    let callbackfu = callback.unwrap();

    for index in set.matches(hay).into_iter() {
        for caps in regexes[index].captures_iter(hay) {
            for i in 0..caps.len() {
                if let Some(group) = caps.get(i) {
                    callbackfu(index, i, group.start(), group.end(), v);
                }
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn replace_string_bytes(
    pattern: *const c_char,
    replace_ptr: *const u8,
    replace_len: usize,
    haystack_ptr: *const u8,
    haystack_len: usize,
    count: usize,
    callback: Option<extern "C" fn(len: usize, result_ptr: *const u8, user: *mut c_void)>,
    user: *mut c_void,
) {
    if pattern.is_null()
        || replace_ptr.is_null()
        || haystack_ptr.is_null()
        || callback.is_none()
        || user.is_null()
    {
        eprintln!("Nullptr passed!");
        return;
    }

    let pat = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("Ptr→str err");
            return;
        }
    };
    let regex = match get_or_compile_bytes_regex(pat) {
        Some(r) => r,
        None => {
            eprintln!("Bad pattern");
            return;
        }
    };

    let replace = slice::from_raw_parts(replace_ptr, replace_len);
    let haystack = slice::from_raw_parts(haystack_ptr, haystack_len);

    let replaced = regex.replacen(haystack, count, replace);

    if let Some(cb) = callback {
        cb(replaced.len(), replaced.as_ptr(), user);
    }
}

#[no_mangle]
pub unsafe extern "C" fn find_iter_bytes(
    pattern: *const c_char,
    hay_ptr: *const u8,
    hay_len: usize,
    callback: Option<extern "C" fn(group: usize, start: usize, end: usize, user: *mut c_void)>,
    user: *mut c_void,
    endpos: usize,
) {
    if pattern.is_null() || hay_ptr.is_null() || callback.is_none() || user.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let pat = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("Ptr→str err");
            return;
        }
    };
    let regex = match get_or_compile_bytes_regex(pat) {
        Some(r) => r,
        None => {
            eprintln!("Bad pattern");
            return;
        }
    };
    let hay = slice::from_raw_parts(hay_ptr, hay_len);
    let cb = callback.unwrap();

    for caps in regex.captures_iter(hay) {
        for i in 0..caps.len() {
            if let Some(grp) = caps.get(i) {
                if grp.end() > endpos {
                    return;
                }
                cb(i, grp.start(), grp.end(), user);
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn split_bytes(
    pattern: *const c_char,
    hay_ptr: *const u8,
    hay_len: usize,
    maxsplit: usize,
    callback: Option<extern "C" fn(len: usize, part_ptr: *const c_char, user: *mut c_void)>,
    user: *mut c_void,
) {
    if pattern.is_null() || hay_ptr.is_null() || callback.is_none() || user.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let pat = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("Ptr→str err");
            return;
        }
    };
    let regex = match get_or_compile_bytes_regex(pat) {
        Some(r) => r,
        None => {
            eprintln!("Bad pattern");
            return;
        }
    };
    let hay = slice::from_raw_parts(hay_ptr, hay_len);
    let cb = callback.unwrap();

    if maxsplit == 0 {
        for part in regex.split(hay) {
            cb(part.len(), part.as_ptr() as *const c_char, user);
        }
    } else {
        for part in regex.splitn(hay, maxsplit) {
            cb(part.len(), part.as_ptr() as *const c_char, user);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn is_match_bytes(
    pattern: *const c_char,
    hay_ptr: *const u8,
    hay_len: usize,
) -> usize {
    if pattern.is_null() || hay_ptr.is_null() {
        eprintln!("Nullptr passed!");
        return 0;
    }

    let pat = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("Ptr→str err");
            return 0;
        }
    };

    let regex = match get_or_compile_bytes_regex(pat) {
        Some(r) => r,
        None => {
            eprintln!("Bad pattern");
            return 0;
        }
    };

    let hay = slice::from_raw_parts(hay_ptr, hay_len);
    regex.is_match(hay) as usize
}

#[no_mangle]
pub unsafe extern "C" fn find_bytes(
    pattern: *const c_char,
    hay_ptr: *const u8,
    hay_len: usize,
    callback: Option<extern "C" fn(start: usize, end: usize, user: *mut c_void)>,
    user: *mut c_void,
    endpos: usize,
) {
    if pattern.is_null() || hay_ptr.is_null() || callback.is_none() || user.is_null() {
        eprintln!("Nullptr passed!");
        return;
    }

    let pat = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => {
            eprintln!("Ptr→str err");
            return;
        }
    };

    let regex = match get_or_compile_bytes_regex(pat) {
        Some(r) => r,
        None => {
            eprintln!("Bad pattern");
            return;
        }
    };

    let hay = slice::from_raw_parts(hay_ptr, hay_len);

    if let Some(mat) = regex.find(hay) {
        if mat.end() > endpos {
            return;
        }
        let cb = callback.unwrap();
        cb(mat.start(), mat.end(), user);
    }
}

#[no_mangle]
pub extern "C" fn clean_regex_cache() {
    if let Ok(mut c) = REGEX_CACHE_STR.lock() {
        c.clear();
    }
    if let Ok(mut c) = REGEX_CACHE_BYTES.lock() {
        c.clear();
    }
    if let Ok(mut c) = REGEX_SET_CACHE_STR.lock() {
        c.clear();
    }
    if let Ok(mut c) = REGEX_SET_CACHE_BYTES.lock() {
        c.clear();
    }
}
