// asaot.three.utils.BufferGeometryUtils -- mergeGeometries, three.js style.
//
// Borrows mergeGeometries from three.js
// examples/jsm/utils/BufferGeometryUtils.js (r187). Given N geometries with
// identical attribute sets, it concatenates every attribute's array into one
// buffer and offsets the index buffer by the running vertex count, so a whole
// scene of parts becomes a single draw call.
//
// Contract (identical to three.js): returns null and traces the reason when the
// geometries are incompatible -- mixed indexed/non-indexed, different attribute
// NAMES, or the same name with a different itemSize. three.js calls
// console.error; AS3's equivalent is trace (there is no console in an AIR app).
//
// DIVERGENCES (three-api-design.md §16):
//   D65  AS3 has no `for (const name in object)` over a Dictionary with a
//        guaranteed order, so the attribute set is walked through
//        BufferGeometry.attributeNames (D64) instead of Object.keys.
//   D-index  the merged index is a Vector.<Number> itemSize 1 (the engine-wide
//        index representation), so offsets are widened to Number at push time.
package asaot.three.utils
{
    import flash.utils.Dictionary;

    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;

    public class BufferGeometryUtils
    {
        public function BufferGeometryUtils()
        {
            // static-only utility
        }

        public static function mergeGeometries(geometries:Vector.<BufferGeometry>,
                                               useGroups:Boolean = false):BufferGeometry
        {
            if (geometries == null || geometries.length == 0) return null;

            var first:BufferGeometry = geometries[0];
            var isIndexed:Boolean = (first.index != null);

            // D64: insertion-ordered attribute names, the JS Object.keys order.
            var names:Vector.<String> = first.attributeNames;
            var nameCount:int = names.length;
            if (nameCount == 0) return null;

            var merged:BufferGeometry = new BufferGeometry();

            var offset:int = 0;
            var i:int;

            // ---- validation pass ----
            for (i = 0; i < geometries.length; i++)
            {
                var geometry:BufferGeometry = geometries[i];

                if (isIndexed != (geometry.index != null))
                {
                    trace("asaot3d BufferGeometryUtils.mergeGeometries: geometry at index " + i +
                          " has an incompatible index (all geometries must be indexed or none).");
                    return null;
                }

                // Same names, same itemSize, same normalized flag.
                for (var n:int = 0; n < nameCount; n++)
                {
                    var name:String = names[n];
                    var mine:BufferAttribute = geometry.getAttribute(name);
                    if (mine == null)
                    {
                        trace("asaot3d BufferGeometryUtils.mergeGeometries: geometry at index " + i +
                              " is missing attribute '" + name + "'.");
                        return null;
                    }
                    var ref:BufferAttribute = first.getAttribute(name);
                    if (mine.itemSize != ref.itemSize)
                    {
                        trace("asaot3d BufferGeometryUtils.mergeGeometries: attribute '" + name +
                              "' at index " + i + " has itemSize " + mine.itemSize +
                              " but the first geometry has " + ref.itemSize + ".");
                        return null;
                    }
                }

                // Extra attributes on a later geometry would be silently dropped,
                // so reject them (three.js does the same).
                if (geometry.attributeNames.length != nameCount)
                {
                    trace("asaot3d BufferGeometryUtils.mergeGeometries: geometry at index " + i +
                          " has a different attribute set than the first geometry.");
                    return null;
                }

                if (useGroups)
                {
                    var count:int;
                    if (isIndexed) count = geometry.index.count;
                    else count = geometry.getAttribute("position").count;

                    merged.addGroup(offset, count, i);
                    offset += count;
                }
            }

            // ---- merge attributes ----
            for (var a:int = 0; a < nameCount; a++)
            {
                var attrName:String = names[a];
                var refAttr:BufferAttribute = first.getAttribute(attrName);
                var itemSize:int = refAttr.itemSize;

                var totalFloats:int = 0;
                for (i = 0; i < geometries.length; i++)
                {
                    totalFloats += geometries[i].getAttribute(attrName).count * itemSize;
                }

                var mergedArray:Vector.<Number> = new Vector.<Number>(totalFloats);
                var write:int = 0;
                for (i = 0; i < geometries.length; i++)
                {
                    var src:BufferAttribute = geometries[i].getAttribute(attrName);
                    var srcArr:Vector.<Number> = src.array;
                    var len:int = src.count * itemSize;
                    for (var k:int = 0; k < len; k++)
                    {
                        mergedArray[write] = srcArr[k];
                        write++;
                    }
                }

                merged.setAttribute(attrName, new BufferAttribute(mergedArray, itemSize, refAttr.normalized));
            }

            // ---- merge index ----
            if (isIndexed)
            {
                var totalIndices:int = 0;
                for (i = 0; i < geometries.length; i++) totalIndices += geometries[i].index.count;

                var mergedIndex:Vector.<Number> = new Vector.<Number>(totalIndices);
                var out:int = 0;
                var vertexOffset:int = 0;
                for (i = 0; i < geometries.length; i++)
                {
                    var idx:BufferAttribute = geometries[i].index;
                    var idxArr:Vector.<Number> = idx.array;
                    for (k = 0; k < idx.count; k++)
                    {
                        mergedIndex[out] = idxArr[k] + vertexOffset;
                        out++;
                    }
                    vertexOffset += geometries[i].getAttribute("position").count;
                }

                merged.setIndex(new BufferAttribute(mergedIndex, 1));
            }

            // Bounding volumes are stale by construction, so drop any that leaked
            // in from the first geometry (a fresh BufferGeometry has none).
            merged.boundingBox = null;
            merged.boundingSphere = null;

            return merged;
        }
    }
}