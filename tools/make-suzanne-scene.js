// make-suzanne-scene.js -- wraps the bare BufferGeometry JSON downloaded from
// three.js r187 examples/models/json into an ObjectLoader scene envelope
// (format 4.5): { metadata, geometries[], materials[], object }.
//
// Provenance: suzanne_buffergeometry.json is from the three.js repository
// (MIT), tag r187, path examples/models/json/suzanne_buffergeometry.json;
// the monkey model originates from Blender. Used here as a REGRESSION TEST
// ASSET only, not shipped as product art.
//
// Usage: node tools/make-suzanne-scene.js
'use strict';
const fs = require('fs');
const path = require('path');

const src = path.join(__dirname, '..', 'assets', 'models', 'suzanne_buffergeometry.json');
const dst = path.join(__dirname, '..', 'assets', 'models', 'suzanne-scene.json');

const geometry = JSON.parse(fs.readFileSync(src, 'utf8'));

// The scene envelope references the geometry by uuid; the bare io_three file
// carries none, so one is assigned here (three.js Scene.toJSON does the same
// when exporting). Scene.toJSON's geometry entries also carry a top-level
// type discriminator, which ObjectLoader.parseGeometries switches on -- the
// bare io_three file keeps the type in metadata.type only.
geometry.uuid = '9a3b-suzanne-geometry';
geometry.type = 'BufferGeometry';

const scene = {
  metadata: { version: 4.5, type: 'Object', generator: 'asaot3d tools/make-suzanne-scene.js' },
  geometries: [geometry],
  materials: [
    {
      uuid: '9a3b-suzanne-material',
      type: 'MeshStandardMaterial',
      name: 'suzanne-mat',
      color: 0x6aa4e8,
      roughness: 0.35,
      metalness: 0.05
    }
  ],
  object: {
    uuid: '9a3b-suzanne-scene',
    type: 'Scene',
    name: 'suzanne-scene',
    children: [
      {
        uuid: '9a3b-suzanne-root',
        type: 'Group',
        name: 'suzanne-holder',
        children: [
          {
            uuid: '9a3b-suzanne-mesh',
            type: 'Mesh',
            name: 'suzanne',
            geometry: '9a3b-suzanne-geometry',
            material: '9a3b-suzanne-material',
            position: [0, 0.2, 0],
            rotation: [0, 0, 0],
            scale: [1.2, 1.2, 1.2]
          }
        ]
      }
    ]
  }
};

fs.writeFileSync(dst, JSON.stringify(scene));
console.log('wrote', dst);
