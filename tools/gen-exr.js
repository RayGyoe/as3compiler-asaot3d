#!/usr/bin/env node
// tools/gen-exr.js -- write the .exr twin of tools/gen-hdr.js's studio panorama.
//
// The radiance function is IMPORTED from gen-hdr.js rather than copied: both
// files must describe the same panorama (same softboxes, same sky), so that
// "the .exr sphere looks like the .hdr sphere" is a real cross-format check of
// the decoder instead of a comparison between two different fixtures.
//
// Output: assets/textures/hdr/studio.exr
//   - 256x128 (half the .hdr's 512x256 resolution: half data is 3x the bytes of
//     RGBE per texel, so the pair still costs about the same on disk)
//   - HALF channels, B/G/R alphabetical chlist order
//   - compression = RLE (default) or NONE (--none), the two EXRLoader decodes
//
// Usage: node tools/gen-exr.js [--none] [outPath]
'use strict';

import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { radiance } from './gen-hdr.js';

const W = 256;
const H = 128;

// ---- OpenEXR half encoder (round-to-nearest-even) -------------------------
const f32 = new Float32Array( 1 );
const u32 = new Uint32Array( f32.buffer );

function half( v ) {
	f32[ 0 ] = v;
	const x = u32[ 0 ];
	const sign = ( x >>> 16 ) & 0x8000;
	const exp = ( x >>> 23 ) & 0xff;
	let mant = x & 0x7fffff;
	if ( exp === 0xff ) return sign | 0x7c00 | ( mant ? 0x200 : 0 );
	const e = exp - 127 + 15;
	if ( e >= 0x1f ) return sign | 0x7c00;
	if ( e <= 0 ) {
		if ( e < -10 ) return sign;
		mant = ( mant | 0x800000 ) >> ( 1 - e );
		return sign | ( ( mant + 0x1000 ) >> 13 );
	}
	return sign | ( e << 10 ) | ( ( mant + 0x1000 ) >> 13 );
}

// ---- OpenEXR header writer ------------------------------------------------
const cstr = ( s ) => Buffer.from( s + '\0', 'latin1' );

const i32 = ( ...values ) => {
	const b = Buffer.alloc( 4 * values.length );
	values.forEach( ( v, i ) => b.writeInt32LE( v, i * 4 ) );
	return b;
};

const f32le = ( v ) => {
	const b = Buffer.alloc( 4 );
	b.writeFloatLE( v, 0 );
	return b;
};

function attr( name, type, data ) {
	return Buffer.concat( [ cstr( name ), cstr( type ), i32( data.length ), data ] );
}

function chlist() {
	const entries = [];
	// The spec requires chlist to be sorted, and the chunk payload follows the
	// same order -- which is why a decoder must look channels up BY NAME.
	for ( const name of [ 'B', 'G', 'R' ] ) {
		entries.push(
			cstr( name ),
			i32( 1 ),                     // pixelType = HALF
			Buffer.from( [ 0, 0, 0, 0 ] ), // pLinear + 3 reserved
			i32( 1, 1 ),                  // xSampling, ySampling
		);
	}
	entries.push( Buffer.from( [ 0 ] ) );
	return Buffer.concat( entries );
}

// OpenEXR's RLE is applied to a PREDICTED and BYTE-SPLIT buffer, not to the raw
// scanline: OpenEXRCore's internal_rle.c does reorder_and_predict() (delta-1 over
// the bytes, then the even indices packed into the first half and the odd ones
// into the second) and only then byte-RLE. Skipping that produces a file that
// decodes cleanly into garbage -- every other decoder disagrees, and the pixels
// look like noise.
function reorderAndPredict( src ) {
	const n = src.length;
	const t = Buffer.alloc( n );
	let a = 0, b = Math.floor( ( n + 1 ) / 2 );
	for ( let i = 0; i < n; i++ ) {
		if ( i % 2 === 0 ) t[ a++ ] = src[ i ];
		else t[ b++ ] = src[ i ];
	}
	let p = t[ 0 ];
	for ( let i = 1; i < n; i++ ) {
		const cur = t[ i ];
		const d = ( ( cur - p + 128 + 256 ) & 0xff );
		t[ i ] = d;
		p = cur;
	}
	return t;
}

// Byte RLE: [-literalCount, bytes...] and [repeatCount-1, value]. A repeat only
// pays off at length >= 3, so shorter runs are emitted as literals.
function rleEncode( src ) {
	const out = [];
	let i = 0;
	while ( i < src.length ) {
		let run = 1;
		while ( i + run < src.length && src[ i + run ] === src[ i ] && run < 128 ) run++;
		if ( run >= 3 ) {
			out.push( run - 1, src[ i ] );
			i += run;
			continue;
		}
		const start = i;
		let count = 0;
		while ( i < src.length && count < 127 ) {
			let r = 1;
			while ( i + r < src.length && src[ i + r ] === src[ i ] && r < 3 ) r++;
			if ( r >= 3 ) break;
			i++;
			count++;
		}
		out.push( 256 - count );
		for ( let k = start; k < start + count; k++ ) out.push( src[ k ] & 0xff );
	}
	return Buffer.from( out );
}

function build( compression ) {
	const magic = Buffer.concat( [ i32( 20000630 ), i32( 2 ) ] ); // v2, scanline image
	const header = Buffer.concat( [
		attr( 'channels', 'chlist', chlist() ),
		attr( 'compression', 'compression', Buffer.from( [ compression ] ) ),
		attr( 'dataWindow', 'box2i', i32( 0, 0, W - 1, H - 1 ) ),
		attr( 'displayWindow', 'box2i', i32( 0, 0, W - 1, H - 1 ) ),
		attr( 'lineOrder', 'lineOrder', Buffer.from( [ 0 ] ) ),
		attr( 'pixelAspectRatio', 'float', f32le( 1 ) ),
		attr( 'screenWindowCenter', 'v2f', Buffer.alloc( 8 ) ),
		attr( 'screenWindowWidth', 'float', f32le( 1 ) ),
		Buffer.from( [ 0 ] ),
	] );

	const chunks = [];
	for ( let y = 0; y < H; y++ ) {
		const payload = [];
		for ( const c of [ 2, 1, 0 ] ) {          // B, G, R -- chlist order
			for ( let x = 0; x < W; x++ ) {
				const [ r, g, b ] = radiance( ( x + 0.5 ) / W, ( y + 0.5 ) / H );
				const v = half( [ r, g, b ][ c ] );
				payload.push( v & 0xff, ( v >> 8 ) & 0xff );
			}
		}
		const raw = Buffer.from( payload );
		// OpenEXR's packing rule: a chunk is stored COMPRESSED only when that makes
		// it strictly smaller. Byte-level RLE gains nothing on half float mantissas
		// (each scanline is 1536 bytes of 1-byte count overhead for every <=127
		// literals), so most RLE files fall back to raw per scanline -- a reader
		// must therefore treat `dataSize == uncompressed size` as "stored raw".
		const packed = compression === 1 ? rleEncode( reorderAndPredict( raw ) ) : raw;
		const body = packed.length < raw.length ? packed : raw;
		chunks.push( Buffer.concat( [ i32( y ), i32( body.length ), body ] ) );
	}

	// Offset table: absolute byte offset of each scanline chunk.
	const headerEnd = magic.length + header.length + H * 8;
	const table = Buffer.alloc( H * 8 );
	let at = headerEnd;
	chunks.forEach( ( c, i ) => {
		table.writeUInt32LE( at >>> 0, i * 8 );
		table.writeUInt32LE( Math.floor( at / 4294967296 ), i * 8 + 4 );
		at += c.length;
	} );

	return Buffer.concat( [ magic, header, table, ...chunks ] );
}

const args = process.argv.slice( 2 );
const compression = args.includes( '--none' ) ? 0 : 1;
const explicit = args.find( ( a ) => !a.startsWith( '--' ) );
const out = resolve( explicit || new URL( '../assets/textures/hdr/studio.exr', import.meta.url ).pathname );
mkdirSync( dirname( out ), { recursive: true } );
const buf = build( compression );
writeFileSync( out, buf );
console.log( `wrote ${out} (${buf.length} bytes, ${W}x${H}, compression=${compression})` );