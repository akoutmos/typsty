//! The worker's memory limit: an allocator that counts the bytes allocated, and ends the
//! process when they would go over the limit. The pool reports that as the render using too
//! much memory, and starts a new worker.
//!
//! Operating systems can't do this portably (macOS doesn't enforce `RLIMIT_AS`, and Windows
//! needs job objects), and this behaves the same everywhere. It counts the heap, which is
//! where Typst's memory goes; stacks and memory-mapped font files aren't counted.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::exit;

pub struct Limited;

static LIMIT: AtomicUsize = AtomicUsize::new(usize::MAX);
static USED: AtomicUsize = AtomicUsize::new(0);

/// Sets the most bytes the process may allocate. `0` means no limit.
pub fn set_limit(limit: usize) {
    let limit = if limit == 0 { usize::MAX } else { limit };
    LIMIT.store(limit, Ordering::Relaxed);
}

pub fn limit() -> Option<usize> {
    match LIMIT.load(Ordering::Relaxed) {
        usize::MAX => None,
        limit => Some(limit),
    }
}

pub fn used() -> usize {
    USED.load(Ordering::Relaxed)
}

impl Limited {
    fn reserve(size: usize) {
        let used = USED.fetch_add(size, Ordering::Relaxed).saturating_add(size);
        if used > LIMIT.load(Ordering::Relaxed) {
            // Nothing may allocate here, so the process ends right away
            exit::now(exit::MEMORY_LIMIT);
        }
    }

    fn release(size: usize) {
        USED.fetch_sub(size, Ordering::Relaxed);
    }
}

unsafe impl GlobalAlloc for Limited {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        Self::reserve(layout.size());
        let pointer = System.alloc(layout);
        if pointer.is_null() {
            Self::release(layout.size());
        }
        pointer
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        Self::reserve(layout.size());
        let pointer = System.alloc_zeroed(layout);
        if pointer.is_null() {
            Self::release(layout.size());
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        System.dealloc(pointer, layout);
        Self::release(layout.size());
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let old_size = layout.size();
        if new_size > old_size {
            Self::reserve(new_size - old_size);
        }

        let new_pointer = System.realloc(pointer, layout, new_size);

        if new_pointer.is_null() {
            if new_size > old_size {
                Self::release(new_size - old_size);
            }
        } else if new_size < old_size {
            Self::release(old_size - new_size);
        }

        new_pointer
    }
}
