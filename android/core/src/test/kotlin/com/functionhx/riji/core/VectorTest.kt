package com.functionhx.riji.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** 跨平台测试向量（spec/test-vectors/）：Kotlin 实现必须与参考实现逐字节一致。 */
class VectorTest {
    private val dir = File(System.getProperty("riji.vectors") ?: "../../spec/test-vectors")
    private fun vector(name: String) = JsonValue.parse(File(dir, name).readText())

    @Test fun canonicalJson() {
        for (item in vector("canonical-json.json")["cases"]!!.array!!) {
            assertEquals(item["output"]!!.string, item["input"]!!.canonical())
        }
    }

    @Test fun hlc() {
        val v = vector("hlc.json")
        for (item in v["format"]!!.array!!) {
            val clock = Hlc(item["ms"]!!.long!!, item["counter"]!!.int!!, item["device"]!!.string!!)
            assertEquals(item["text"]!!.string, clock.toString())
            assertEquals(clock, Hlc.parse(item["text"]!!.string!!))
        }
        for (text in v["invalid"]!!.array!!) assertFailsWith<IllegalArgumentException> { Hlc.parse(text.string!!) }
        for (item in v["compare"]!!.array!!) {
            val result = Hlc.parse(item["a"]!!.string!!).compareTo(Hlc.parse(item["b"]!!.string!!)).coerceIn(-1, 1)
            assertEquals(item["result"]!!.int, result)
        }
        for (item in v["tick"]!!.array!!) {
            val last = item["last"]!!.string?.let(Hlc::parse)
            assertEquals(item["result"]!!.string, Hlc.tick(last, item["wall"]!!.long!!, item["device"]!!.string!!).toString())
        }
        for (item in v["receive"]!!.array!!) {
            val last = item["last"]!!.string?.let(Hlc::parse)
            val next = Hlc.receive(last, Hlc.parse(item["remote"]!!.string!!), item["wall"]!!.long!!, item["device"]!!.string!!)
            assertEquals(item["result"]!!.string, next.toString())
        }
    }

    @Test fun keyDerivation() {
        val v = vector("kdf.json")
        val root = v["root"]!!.string!!.hexToBytes()
        val salt = v["riji_salt"]!!.string!!.hexToBytes()
        val keys = mutableMapOf<Int, ByteArray>()
        for (item in v["riji_keys"]!!.array!!) {
            val epoch = item["epoch"]!!.int!!
            keys[epoch] = RijiCrypto.deriveRijiKey(root, salt, epoch)
            assertEquals(item["key"]!!.string, keys.getValue(epoch).toHex())
        }
        for (item in v["segment_keys"]!!.array!!) {
            val key = RijiCrypto.deriveSegmentKey(keys.getValue(item["epoch"]!!.int!!), item["device"]!!.string!!, item["seq"]!!.int!!)
            assertEquals(item["key"]!!.string, key.toHex())
        }
    }

    @Test fun segmentsOpenSealAndDetectTampering() {
        val v = vector("segments.json")
        val rijiKey = v["riji_key_epoch_1"]!!.string!!.hexToBytes()
        for ((_, json) in v["segments"]!!.obj!!) {
            val original = Segment.from(json)
            val changes = original.open(rijiKey)
            assertTrue(changes.isNotEmpty())
            assertEquals(original.hlcMax, changes.maxOf { it.hlc }.toString())
            // 用同一个 nonce 重新封装必须逐字节相同。
            val nonce = Base64Url.decode(original.ct).copyOf(12)
            assertEquals(original, Segment.seal(rijiKey, original.device, original.seq, original.prev, original.epoch, changes, nonce))
        }
        for ((name, hash) in v["chain_hashes"]!!.obj!!) assertEquals(hash.string, Segment.from(v["segments"]!![name]!!).chainHash)
        for (item in v["must_fail_to_open"]!!.array!!) {
            assertFailsWith<SegmentAuthenticationException>(item["reason"]!!.string) { Segment.from(item["segment"]!!).open(rijiKey) }
        }
    }

    @Test fun mergeScenarios() {
        val segments = vector("segments.json")
        val merge = vector("merge.json")
        val rijiKey = segments["riji_key_epoch_1"]!!.string!!.hexToBytes()
        for (scenario in merge["scenarios"]!!.array!!) {
            val list = scenario["segments"]!!.array!!.map { name ->
                val text = name.string!!
                if (text.endsWith("(forged-prev)")) Segment.from(merge["forged_prev_segment"]!!) else Segment.from(segments["segments"]!![text]!!)
            }
            val result = Merge.materialize(rijiKey, list)
            val label = scenario["name"]!!.string
            assertEquals(scenario["expected_vector"], JsonValue.Obj(result.vector.mapValues { JsonValue.num(it.value) }), label)
            assertEquals(scenario["expected_problems"], JsonValue.Obj(result.problems.mapValues { (_, list) -> JsonValue.Arr(list.map { it.json() }) }), label)
            assertEquals(scenario["expected_state"]!!.canonical(), result.stateJson().canonical(), label)
            assertEquals(scenario["expected_state_digest"]!!.string, result.digest(), label)
        }
    }

    @Test fun pairing() {
        val v = vector("pairing.json")
        val code = v["code"]!!.string!!
        val a = Pairing.fromScalar(v["a"]!!["private_d_hex"]!!.string!!.hexToBytes())
        val b = Pairing.fromScalar(v["b"]!!["private_d_hex"]!!.string!!.hexToBytes())
        assertEquals(v["a"]!!["public"]!!.string, a.publicKey)
        assertEquals(v["b"]!!["public"]!!.string, b.publicKey)
        val sharedA = Pairing.shared(a, b.publicKey)
        val sharedB = Pairing.shared(b, a.publicKey)
        assertEquals(v["shared_hex"]!!.string, sharedA.toHex())
        assertEquals(sharedA.toHex(), sharedB.toHex())
        val transcript = Pairing.transcript(code, a.publicKey, b.publicKey)
        assertEquals(v["transcript_hex"]!!.string, transcript.toHex())
        val (key, sas) = Pairing.keys(sharedB, transcript)
        assertEquals(v["pair_key_hex"]!!.string, key.toHex())
        assertEquals(v["sas"]!!.string, sas)
        assertEquals(v["sealed"]!!.string, Pairing.seal(key, code, v["payload"]!!, v["nonce_hex"]!!.string!!.hexToBytes()))
        assertEquals(v["payload"]!!.canonical(), Pairing.open(key, code, v["sealed"]!!.string!!).canonical())
        assertFailsWith<Pairing.BadEnvelope> { Pairing.open(key, "00000000", v["sealed"]!!.string!!) }
        val m = Pairing.fromScalar(v["mitm"]!!["m_private_d_hex"]!!.string!!.hexToBytes())
        assertEquals(v["mitm"]!!["sas_seen_by_a"]!!.string, Pairing.keys(Pairing.shared(a, m.publicKey), Pairing.transcript(code, a.publicKey, m.publicKey)).second)
        // 随机生成的密钥对也能互通
        val x = Pairing.generate(); val y = Pairing.generate()
        assertEquals(Pairing.shared(x, y.publicKey).toHex(), Pairing.shared(y, x.publicKey).toHex())
    }
}
