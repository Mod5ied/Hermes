#![no_std]

use core::slice;

const BUFFER_CAPACITY: usize = 262_144;
static mut INPUT_BUFFER: [f32; BUFFER_CAPACITY] = [0.0; BUFFER_CAPACITY];
static mut OUTPUT_BUFFER: [i16; BUFFER_CAPACITY] = [0; BUFFER_CAPACITY];

#[panic_handler]
fn panic(_: &core::panic::PanicInfo<'_>) -> ! {
    loop {}
}

#[no_mangle]
pub extern "C" fn hermes_input_ptr() -> *mut f32 {
    core::ptr::addr_of_mut!(INPUT_BUFFER).cast::<f32>()
}

#[no_mangle]
pub extern "C" fn hermes_output_ptr() -> *mut i16 {
    core::ptr::addr_of_mut!(OUTPUT_BUFFER).cast::<i16>()
}

#[no_mangle]
pub extern "C" fn hermes_buffer_capacity() -> usize { BUFFER_CAPACITY }

/// Computes root-mean-square energy without allocating. The caller owns the
/// WebAssembly linear-memory range for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn hermes_rms(pointer: *const f32, length: usize) -> f32 {
    if pointer.is_null() || length == 0 {
        return 0.0;
    }
    let input = slice::from_raw_parts(pointer, length);
    let sum = input.iter().fold(0.0_f32, |value, sample| value + sample * sample);
    sqrt(sum / length as f32)
}

/// Downsamples mono f32 PCM into i16 PCM using bounded box filtering. Returns
/// the number of samples written; no heap allocation or copies are performed.
#[no_mangle]
pub unsafe extern "C" fn hermes_downsample_i16(
    input_pointer: *const f32,
    input_length: usize,
    output_pointer: *mut i16,
    output_capacity: usize,
    input_rate: u32,
    output_rate: u32,
) -> usize {
    if input_pointer.is_null() || output_pointer.is_null() || input_rate == 0 || output_rate == 0 {
        return 0;
    }
    let input = slice::from_raw_parts(input_pointer, input_length);
    let output = slice::from_raw_parts_mut(output_pointer, output_capacity);
    let ratio = input_rate as f32 / output_rate as f32;
    let expected = ((input_length as f32 / ratio) as usize).min(output_capacity);
    for out_index in 0..expected {
        let start = (out_index as f32 * ratio) as usize;
        let end = (((out_index + 1) as f32 * ratio) as usize).min(input_length).max(start + 1);
        let sum = input[start..end].iter().fold(0.0_f32, |value, sample| value + sample);
        let value = sum / (end - start) as f32;
        let bounded = if value < -1.0 { -1.0 } else if value > 1.0 { 1.0 } else { value };
        output[out_index] = (bounded * 32767.0) as i16;
    }
    expected
}

fn sqrt(value: f32) -> f32 {
    if value <= 0.0 { return 0.0; }
    let mut estimate = if value > 1.0 { value } else { 1.0 };
    for _ in 0..6 { estimate = 0.5 * (estimate + value / estimate); }
    estimate
}
