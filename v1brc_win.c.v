// vtest build: windows
// v1brc_win.c.v - Multi-thread V 1BRC for Windows, single file
// Rewritten for Win32 (CreateFileMapping / MapViewOfFile), algorithm mirrors v1brc.v.
// Compile: v -prod -cc gcc -skip-unused -no-bounds-checking -cflags "-std=c17 -march=native -mtune=native" -o v1brc_win.exe v1brc_win.c.v
// Run: v1brc_win.exe data.txt [-n threads]
module main

import os
import runtime

#include <string.h>
#include <windows.h>
#include <immintrin.h>

// AVX2 byte scan compiled with -march=native; MSVCRT memchr is not SIMD-tuned,
// so we supply our own to match glibc's memchr speed on Linux.
// Statement-expression macro (GCC extension, needs -std=gnu17).
#define avx2_memchr(PTR, CH, COUNT) ({ const unsigned char* _p = (const unsigned char*)(PTR); int _ch = (CH); unsigned long long _n = (COUNT); __m256i _vch = _mm256_set1_epi8((char)(unsigned char)_ch); unsigned long long _i = 0; void* _r = 0; for (; _i + 32 <= _n; _i += 32) { __m256i _v = _mm256_loadu_si256((const __m256i*)(_p + _i)); int _m = _mm256_movemask_epi8(_mm256_cmpeq_epi8(_v, _vch)); if (_m) { _r = (void*)(_p + _i + (unsigned long long)__builtin_ctz(_m)); break; } } if (!_r) { for (; _i < _n; _i++) { if (_p[_i] == (unsigned char)_ch) { _r = (void*)(_p + _i); break; } } } _r; })
// AVX2 scan returning a 32-bit mask of positions that are ';' (59) or '\n' (10).
#define avx2_delim_mask(PTR) ({ __m256i _v = _mm256_loadu_si256((const __m256i*)(PTR)); __m256i _sc = _mm256_cmpeq_epi8(_v, _mm256_set1_epi8((char)59)); __m256i _nl = _mm256_cmpeq_epi8(_v, _mm256_set1_epi8((char)10)); (unsigned int)(_mm256_movemask_epi8(_mm256_or_si256(_sc, _nl))); })

fn C.avx2_memchr(ptr voidptr, ch int, count u64) voidptr
fn C.avx2_delim_mask(ptr voidptr) u32
fn C.__builtin_ctz(x u32) int
fn C.memchr(ptr voidptr, ch int, count u64) voidptr
fn C.memcpy(dst voidptr, src voidptr, n u64) voidptr
fn C.memcmp(a voidptr, b voidptr, n u64) int

fn C.CreateFileA(name &char, access u32, share u32, sec voidptr, disp u32, flags u32, templ voidptr) voidptr
fn C.CreateFileMappingA(file voidptr, attrs voidptr, protect u32, max_hi u32, max_lo u32, name &char) voidptr
fn C.MapViewOfFile(mapping voidptr, access u32, off_hi u32, off_lo u32, bytes usize) voidptr
fn C.UnmapViewOfFile(base voidptr) int
fn C.CloseHandle(h voidptr) int
fn C.GetFileSizeEx(file voidptr, size &i64) int
fn C.QueryPerformanceCounter(count &i64) int
fn C.QueryPerformanceFrequency(freq &i64) int

const max_city_len = 64
const hash_cap = 1 << 12

const generic_read = u32(0x80000000)
const file_share_read = u32(0x00000001)
const open_existing = u32(3)
const file_attribute_normal = u32(0x00000080)
const file_flag_sequential = u32(0x08000000)
const page_readonly = u32(0x00000002)
const file_map_read = u32(0x00000004)

struct CityHashEntry {
mut:
	hash   u32
	length u8
	name   [max_city_len]u8
	min    i32
	max    i32
	sum    i64
	count  u32
}

struct CityHashMap {
mut:
	entries []CityHashEntry
	count   u32
}

fn new_hash_map() CityHashMap {
	return CityHashMap{
		entries: []CityHashEntry{len: int(hash_cap)}
	}
}

@[inline]
fn hash_bytes(addr &u8, offset u64, len u32) u32 {
	unsafe {
		if len >= 8 {
			val := *(&u64(&addr[offset]))
			mut h := u32(val) * 0x45d9f3b
			h ^= u32(val >> 32) * 0x45d9f3b
			h ^= h >> 16
			return h
		}
		mut h := u32(2166136261)
		mut i := u32(0)
		for i + 4 <= len {
			v := *(&u32(&addr[offset + u64(i)]))
			h = h ^ (v & 0xff)
			h = h * 16777619
			h = h ^ ((v >> 8) & 0xff)
			h = h * 16777619
			h = h ^ ((v >> 16) & 0xff)
			h = h * 16777619
			h = h ^ ((v >> 24) & 0xff)
			h = h * 16777619
			i += 4
		}
		for i < len {
			h = h ^ u32(addr[offset + u64(i)])
			h = h * 16777619
			i++
		}
		return h
	}
}

@[direct_array_access]
@[inline]
fn name_eq(a &u8, b &u8, len u8) bool {
	unsafe {
		mut i := 0
		for i + 8 <= int(len) {
			if *(&u64(&a[i])) != *(&u64(&b[i])) {
				return false
			}
			i += 8
		}
		for i < int(len) {
			if a[i] != b[i] {
				return false
			}
			i++
		}
		return true
	}
}

@[inline]
fn (mut m CityHashMap) find_or_insert(addr &u8, offset u64, len u8) &CityHashEntry {
	if len == 0 || len > max_city_len {
		panic('invalid city length')
	}
	mut h := hash_bytes(addr, offset, u32(len))
	mut idx := int(h & (hash_cap - 1))
	for {
		mut e := &m.entries[idx]
		if e.count == 0 {
			e.hash = h
			e.length = len
			unsafe { C.memcpy(voidptr(&e.name[0]), voidptr(&addr[offset]), u64(len)) }
			e.min = 0x7fffffff
			e.max = 0x80000000
			e.sum = 0
			m.count++
			return e
		}
		if e.hash == h && e.length == len
			&& unsafe { name_eq(&e.name[0], &addr[offset], len) } {
			return e
		}
		idx = (idx + 1) & (hash_cap - 1)
	}
	return &m.entries[0]
}

fn format_value(value i32) string {
	if value < 0 {
		abs := -value
		return '-${abs / 10}.${abs % 10}'
	}
	return '${value / 10}.${value % 10}'
}

fn print_results(results CityHashMap, print_nicely bool) {
	mut output := []string{cap: int(results.count)}
	for e in results.entries {
		if e.count == 0 {
			continue
		}
		name := unsafe { tos(&e.name[0], int(e.length)) }
		mean := f64(e.sum) / f64(e.count) / 10.0
		output << '${name}=${format_value(e.min)}/${mean:.1f}/${format_value(e.max)}'
	}
	output.sort()
	if print_nicely {
		println(output.join('\n'))
	} else {
		println('{' + output.join(', ') + '}')
	}
}

@[direct_array_access]
@[inline]
fn parse_temp(addr &u8, start u64, len int) i32 {
	unsafe {
		if len == 3 {
			return i32(addr[start] - 48) * 10 + i32(addr[start + 2] - 48)
		}
		if len == 4 {
			if addr[start] == `-` {
				return -(i32(addr[start + 1] - 48) * 10 + i32(addr[start + 3] - 48))
			}
			return i32(addr[start] - 48) * 100 + i32(addr[start + 1] - 48) * 10 +
				i32(addr[start + 3] - 48)
		}
		return -(i32(addr[start + 1] - 48) * 100 + i32(addr[start + 2] - 48) * 10 +
			i32(addr[start + 4] - 48))
	}
}

@[direct_array_access]
@[inline]
fn (mut m CityHashMap) handle_delim(addr &u8, pos u64, is_semi bool, city_start u64, semi u64) (u64, u64) {
	unsafe {
		if is_semi {
			return city_start, pos
		}
		if semi > city_start {
			mut temp_end := pos
			if pos > 0 && addr[pos - 1] == `\r` {
				temp_end = pos - 1
			}
			city_len := u8(semi - city_start)
			temp_len := int(temp_end - (semi + 1))
			if temp_len > 0 {
				temp := parse_temp(addr, semi + 1, temp_len)
				mut e := m.find_or_insert(addr, city_start, city_len)
				if temp > e.max {
					e.max = temp
				}
				if temp < e.min {
					e.min = temp
				}
				e.sum += i64(temp)
				e.count++
			}
		}
		return pos + 1, u64(0)
	}
}

@[direct_array_access]
fn process_chunk(addr &u8, from u64, to u64) CityHashMap {
	mut results := new_hash_map()
	mut city_start := from
	mut semi := u64(0)
	mut i := from

	unsafe {
		for i + 32 <= to {
			msk := C.avx2_delim_mask(voidptr(&addr[int(i)]))
			mut b := msk
			for b != 0 {
				bit := u32(C.__builtin_ctz(b))
				p := i + u64(bit)
				c := addr[p]
				city_start, semi = results.handle_delim(addr, p, c == `;`, city_start, semi)
				b &= b - 1
			}
			i += 32
		}
		for i < to {
			c := addr[i]
			if c == `;` || c == `\n` {
				city_start, semi = results.handle_delim(addr, i, c == `;`, city_start, semi)
			}
			i++
		}
	}
	return results
}

fn combine_results(chunks []CityHashMap) CityHashMap {
	mut result := new_hash_map()
	for chunk in chunks {
		for e in chunk.entries {
			if e.count == 0 {
				continue
			}
			mut target := result.find_or_insert(&e.name[0], 0, e.length)
			target.sum += e.sum
			target.count += e.count
			if e.min < target.min {
				target.min = e.min
			}
			if e.max > target.max {
				target.max = e.max
			}
		}
	}
	return result
}

struct MemoryMappedFile {
	size u64
mut:
	data    &u8
	file    voidptr
	mapping voidptr
}

fn mmap_file(path string) MemoryMappedFile {
	file := C.CreateFileA(&char(path.str), generic_read, file_share_read, C.NULL, open_existing,
		file_attribute_normal | file_flag_sequential, C.NULL)
	if voidptr(file) == voidptr(-1) {
		panic('failed to open file: ${path}')
	}
	mut fsize := i64(0)
	if C.GetFileSizeEx(file, &fsize) == 0 {
		C.CloseHandle(file)
		panic('GetFileSizeEx failed')
	}
	mapping := C.CreateFileMappingA(file, C.NULL, page_readonly, 0, 0, C.NULL)
	if mapping == C.NULL {
		C.CloseHandle(file)
		panic('CreateFileMapping failed')
	}
	data := &u8(C.MapViewOfFile(mapping, file_map_read, 0, 0, usize(0)))
	if data == C.NULL {
		C.CloseHandle(mapping)
		C.CloseHandle(file)
		panic('MapViewOfFile failed')
	}
	return MemoryMappedFile{
		size:    u64(fsize)
		data:    data
		file:    file
		mapping: mapping
	}
}

fn (mut mf MemoryMappedFile) unmap() {
	C.UnmapViewOfFile(mf.data)
	C.CloseHandle(mf.mapping)
	C.CloseHandle(mf.file)
}

fn qpc_now() i64 {
	mut c := i64(0)
	C.QueryPerformanceCounter(&c)
	return c
}

fn qpc_freq() i64 {
	mut f := i64(0)
	C.QueryPerformanceFrequency(&f)
	return f
}

fn process_in_parallel(mf MemoryMappedFile, thread_count u32) CityHashMap {
	mut threads := []thread CityHashMap{}
	approx_chunk_size := mf.size / u64(thread_count)
	mut from := u64(0)
	mut to := approx_chunk_size

	for _ in 0 .. thread_count - 1 {
		if to >= mf.size {
			break
		}
		p := unsafe { C.avx2_memchr(voidptr(&mf.data[int(to)]), int(`\n`), mf.size - to) }
		if p == C.NULL {
			break
		}
		to = unsafe { u64(p) - u64(voidptr(mf.data)) + 1 }
		if to >= mf.size {
			break
		}
		threads << spawn process_chunk(mf.data, from, to)
		from = to
		to = from + approx_chunk_size
	}
	to = mf.size
	threads << spawn process_chunk(mf.data, from, to)

	return combine_results(threads.wait())
}

fn main() {
	if os.args.len < 2 {
		eprintln('Usage: ${os.args[0]} data.txt [-n threads]')
		exit(1)
	}
	path := os.args[1]

	mut thread_count := u32(runtime.nr_cpus())
	if os.args.len >= 4 && os.args[2] == '-n' {
		thread_count = os.args[3].u32()
	}

	freq := qpc_freq()
	t_start := qpc_now()

	mut mf := mmap_file(path)
	defer {
		mf.unmap()
	}
	results := if thread_count > 1 {
		process_in_parallel(mf, thread_count)
	} else {
		process_chunk(mf.data, 0, mf.size)
	}

	t_end := qpc_now()
	dur_s := f64(t_end - t_start) / f64(freq)
	dur_ms := dur_s * 1000.0

	print_results(results, false)
	mut total_rows := u64(0)
	for e in results.entries {
		if e.count == 0 {
			continue
		}
		total_rows += u64(e.count)
	}
	eprintln('\n[Windows Multi-thread Timing]')
	eprintln('CPU cores used: ${thread_count}')
	eprintln('Distinct cities: ${results.count}   Total rows: ${total_rows}')
	eprintln('Total wall time: ${dur_s:.3f} s (${dur_ms:.2f} ms)')
}
