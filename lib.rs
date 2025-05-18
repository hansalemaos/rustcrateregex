use regex::Regex;
use std::ffi::CStr;
use std::os::raw::{c_char};

// MIT License

// Copyright (c) 2025 Hans Alemão

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.



/// Finds all matches of a regular expression in a given text and calls the
/// provided callback with the start and length of each match.
///
/// # Safety
///
/// This function is marked as `unsafe` because it dereferences the given
/// `pattern` and `text` pointers. The caller must ensure that these pointers
/// are valid and point to zero-terminated strings. The function will return
/// immediately if the pointers are null or if the callback is null.
///
/// The callback is called once for each match of the regular expression in
/// the given text. The callback is passed the start and length of the match
/// as arguments. The callback should not take ownership of the strings;
/// instead, it should copy the relevant parts of the strings if necessary.
///
/// # Errors
///
/// If the regular expression is invalid, the function will return immediately
/// without calling the callback.
///
/// If the callback returns an error, the function will return immediately
/// without calling the callback again.




#[no_mangle]
pub unsafe extern "C" fn for_each_match(
    pattern: *const c_char,
    text: *const c_char,
    callback: Option<extern "C" fn(start: usize, length: usize)>
) {
    if pattern.is_null() || text.is_null() || callback.is_none() {
        return;
    }

    let pattern_str = match CStr::from_ptr(pattern).to_str() {
        Ok(s) => s,
        Err(_) => return,
    };

    let text_str = match CStr::from_ptr(text).to_str() {
        Ok(s) => s,
        Err(_) => return,
    };

    let re = match Regex::new(pattern_str) {
        Ok(r) => r,
        Err(_) => return,
    };

    let callbackfu = callback.unwrap();

    for mat in re.find_iter(text_str) {
        callbackfu(mat.start(), mat.end());
    }
}
