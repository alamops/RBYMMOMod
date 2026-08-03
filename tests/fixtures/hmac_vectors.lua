-- HMAC-SHA256 / SHA-256 test vectors, pinning src/Sha256.lua against two
-- independent sources of truth.
--
-- Section 1 (RFC_HMAC) and Section 2 (SHA256) are the published standard:
-- RFC 4231 test cases 1, 2, 3 and 6, and the textbook SHA-256 vectors for the
-- empty string, "abc", and the 56-byte multi-block string. These pin the
-- primitive against the spec, not against itself.
--
-- Section 3 (KAT) is the fixed known-answer vector already carried by
-- server/auth.test.js -- reused here rather than re-derived, so both suites
-- assert the same literal.
--
-- Section 4 (CROSS) is a generated set of (code, nonce) -> digest triples,
-- produced by Node (server/lib/auth.js -- normalizeCode + crypto.createHmac,
-- the same recipe sign() uses) and frozen here as literals. The Lua suite
-- asserts src/Sha256.lua reproduces every one; that is what catches the two
-- implementations drifting apart, since a drift here reaches a player only
-- as "wrong join code" with nothing else to go on.
--
-- HOW THIS FILE WAS GENERATED (and how to regenerate it):
--
--   RFC_HMAC / SHA256 (sections 1-2): computed once with node:crypto against
--   the literal RFC 4231 / FIPS 180-4 inputs. Nothing here depends on this
--   repo's code, so these never need regenerating; they would only change if
--   a transcription error were found.
--
--   CROSS (section 4): run this from the repo root with the Node on PATH
--   (or the one CLAUDE.md names) --
--
--     node -e '
--       const crypto = require("crypto");
--       const auth = require("./server/lib/auth.js");
--       function sign(code, nonce) {
--         const key = auth.normalizeCode(code);
--         return crypto.createHmac("sha256", Buffer.from(key, "ascii"))
--           .update(nonce, "ascii").digest("hex");
--       }
--       console.log(sign("A7K3P9", "<32-hex-nonce>"));
--     '
--
--   which is exactly the recipe auth.sign() documents at the top of
--   server/lib/auth.js, and the one src/Sha256.lua + src/Wire.lua reimplement.
--   Each entry below records its `code` exactly as a player would type or
--   paste it (dashed, undashed, lowercase, messy, with I/L/O/U noise) plus the
--   `normalized` form Wire.code() must reduce it to, so a vector doubles as a
--   normalisation check when read alongside the Wire.code tests in
--   rby_mmo_test.lua.
--
-- No love, no engine modules: a plain table, safe to require from anywhere.

local M = {}

-- ------------------------------------------------------------------
-- 1. RFC 4231 HMAC-SHA256 test vectors (cases 1, 2, 3, 6)
-- ------------------------------------------------------------------
-- key and message are given as hex, since case 1/3/6 keys are raw bytes,
-- not text -- a suite decodes them with a small hex->bytes helper before
-- calling Sha256.hmacHex.  Case 6 is the key-longer-than-the-block path:
-- a 131-byte key gets hashed down to 32 bytes before use.
M.RFC_HMAC = {
  {
    case = 1,
    keyHex = "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b",
    dataHex = "4869205468657265",
    digest = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  },
  {
    case = 2,
    keyHex = "4a656665",
    dataHex = "7768617420646f2079612077616e7420666f72206e6f7468696e673f",
    digest = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  },
  {
    case = 3,
    keyHex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    dataHex = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    digest = "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
  },
  {
    case = 6,
    keyHex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    dataHex = "54657374205573696e67204c6172676572205468616e20426c6f636b2d53697a65204b6579202d2048617368204b6579204669727374",
    digest = "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
  },
}

-- ------------------------------------------------------------------
-- 2. Standard SHA-256 vectors: empty string, "abc", and the 56-byte
--    multi-block string that straddles the single/double-block boundary
-- ------------------------------------------------------------------
M.SHA256 = {
  {
    label = "empty string",
    input = "",
    digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  },
  {
    label = "abc",
    input = "abc",
    digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  },
  {
    label = "56-byte multi-block string",
    input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    digest = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  },
}

-- ------------------------------------------------------------------
-- 3. The cross-language known-answer vector server/auth.test.js already
--    fixes.  Reused verbatim, not re-derived: both suites pin the same
--    literal, so a divergence anywhere shows up as a failure on one side
--    or the other rather than two tests that quietly drift together.
-- ------------------------------------------------------------------
M.KAT = {
  code = "A7K3P9",
  nonce = "a1b2c3d4e5f6070819293a4b5c6d7e8f",
  digest = "56a6349bae6c261ba588e3d29671234ba74ff295d8deb0fff22254e83acf9670",
}

-- ------------------------------------------------------------------
-- 4. Generated cross-language (code, nonce) -> digest triples, produced
--    by Node as described above.  `code` is the input exactly as it would
--    arrive off a player's keyboard or a pasted message; `normalized` is
--    what Wire.code(code) must equal, and what actually gets HMAC-keyed.
-- ------------------------------------------------------------------
M.CROSS = {
  {
    label = "canonical form",
    code = "A7K3P9",
    normalized = "A7K3P9",
    nonce = "cae662172fd450bb0cd710a769079c05",
    digest = "0a30ce88f02a82822cfa9834e6d862347b4ee5af9fd0d8283bdfcbbf9173b5ad",
  },
  {
    label = "lowercase spelling of the same code",
    code = "a7k3p9",
    normalized = "A7K3P9",
    nonce = "cae662172fd450bb0cd710a769079c05",
    digest = "0a30ce88f02a82822cfa9834e6d862347b4ee5af9fd0d8283bdfcbbf9173b5ad",
  },
  {
    label = "spaces stripped from the same code",
    code = " A7K 3P9 ",
    normalized = "A7K3P9",
    nonce = "cae662172fd450bb0cd710a769079c05",
    digest = "0a30ce88f02a82822cfa9834e6d862347b4ee5af9fd0d8283bdfcbbf9173b5ad",
  },
  {
    label = "messy spacing and punctuation, same code",
    code = " a7k-3p9, ?? ",
    normalized = "A7K3P9",
    nonce = "cae662172fd450bb0cd710a769079c05",
    digest = "0a30ce88f02a82822cfa9834e6d862347b4ee5af9fd0d8283bdfcbbf9173b5ad",
  },
  {
    label = "a dash typed out of old 16-character habit",
    code = "A7K-3P9",
    normalized = "A7K3P9",
    nonce = "cae662172fd450bb0cd710a769079c05",
    digest = "0a30ce88f02a82822cfa9834e6d862347b4ee5af9fd0d8283bdfcbbf9173b5ad",
  },
  {
    -- I, L, O and U are outside the alphabet, so they are dropped as noise
    -- like any stray character -- not folded to a lookalike (O -> 0, I -> 1).
    -- A Lua half that aliased them would derive a different key from the
    -- same typed input and every such player would see "wrong passcode".
    label = "I, L, O, U dropped as noise, not aliased -- not folded to 1/0",
    code = "IA7LK3OP9U",
    normalized = "A7K3P9",
    nonce = "cae662172fd450bb0cd710a769079c05",
    digest = "0a30ce88f02a82822cfa9834e6d862347b4ee5af9fd0d8283bdfcbbf9173b5ad",
  },
  {
    label = "alphabet coverage block 1 (offset 0)",
    code = "012345",
    normalized = "012345",
    nonce = "6521606f8a85812aec066190a006e8a7",
    digest = "ab03abeb1607f15ba534c476c52dacfb8009d4b6c4f8c0295a753927769b3f2a",
  },
  {
    label = "alphabet coverage block 2 (offset 6)",
    code = "6789AB",
    normalized = "6789AB",
    nonce = "e59b1474205d8721cc8784c8539d44e1",
    digest = "2737e411a5fa84842699167c393ec0151dca087450c390f635a5390d8bc3484b",
  },
  {
    label = "alphabet coverage block 3 (offset 12)",
    code = "CDEFGH",
    normalized = "CDEFGH",
    nonce = "f2aa1ac251e6613e8b05824940748226",
    digest = "6e72faf1f649a30554f2d61d0f5d6d8e3440da185423eeed758841cbb171eded",
  },
  {
    label = "alphabet coverage block 4 (offset 18)",
    code = "JKMNPQ",
    normalized = "JKMNPQ",
    nonce = "924f31efb185b98b103f157ca64cebe8",
    digest = "c6fa75daae7993243b7df893001800cb08e16eaa7361f1240322c266e251a80f",
  },
  {
    label = "alphabet coverage block 5 (offset 24)",
    code = "RSTVWX",
    normalized = "RSTVWX",
    nonce = "e825819a4bddae455af8b086aae9a53f",
    digest = "b1d646abe2fe23d2ae7b14436bd85a7ef240dc42c27e6ed97559391415f344f0",
  },
  {
    label = "alphabet coverage block 6 (offset 30, wraps to the top)",
    code = "YZ0123",
    normalized = "YZ0123",
    nonce = "384343b7f71365cb97a46f765e9e182c",
    digest = "d0a09d080e9e925dc6b39bc3cfed115d284a6737e0b2c70328b34b15ede70cb3",
  },
  {
    label = "generated code 1 (stride 3)",
    code = "0369CF",
    normalized = "0369CF",
    nonce = "04af6944008245e071741421e4712e4f",
    digest = "c67f777237f69abd677313f2a2f0213ed87e46f89a35ee4976fa9b1271e4d4d6",
  },
  {
    label = "generated code 2 (stride 5)",
    code = "05AFMS",
    normalized = "05AFMS",
    nonce = "1669a4adc518313541a2a973f63152cf",
    digest = "23e06ad6c9e576fc331363ec1041c3577a8831bab5b27e0651c165af2a7404f3",
  },
  {
    label = "generated code 3 (stride 7)",
    code = "07ENW3",
    normalized = "07ENW3",
    nonce = "e30f4eee963fe3d349d9c872965122da",
    digest = "2cf5b06032902e909908c1e0442d6d7c499d2133b44e5d4efc741abcba8ff531",
  },
  {
    label = "generated code 4 (stride 9)",
    code = "09JV4D",
    normalized = "09JV4D",
    nonce = "35e1472bceafdd0cd60fb6ad6c668041",
    digest = "6f43c53002d485a7946c656a40a44405725e059ca0aece5632d01ea29840cfec",
  },
  {
    label = "generated code 5 (stride 11)",
    code = "0BP1CQ",
    normalized = "0BP1CQ",
    nonce = "24bf9350c1ad7c5e8571a8988447d71c",
    digest = "7429f80bfb039752d54c409fe6ab873d23d7dd3bcec6d99513fe5a9923ab84e3",
  },
  {
    label = "generated code 6 (stride 13)",
    code = "0DT7M1",
    normalized = "0DT7M1",
    nonce = "26ad4b341a2e78667d7557ecc9e16f6c",
    digest = "99e6f4b9b8fd1ba49534b918b6eda9304fa44eb4dd3d6586d206256a86f0b5a2",
  },
  {
    label = "generated code 7 (stride 17)",
    code = "0H2K4N",
    normalized = "0H2K4N",
    nonce = "8eacdfcb81b585b785516533a580ad5e",
    digest = "9d38385ca171d30408efd422f2e0d104b0e8bb0ef3022520fb807985824f868a",
  },
  {
    label = "generated code 8 (stride 19)",
    code = "0K6SCZ",
    normalized = "0K6SCZ",
    nonce = "01f90f64e3787939997c025dac8f0e63",
    digest = "0878999a8ad87d30cd17a8ea207a4d7b0838bd580fc06025988b2078f3be2edf",
  },
  {
    label = "dashed spelling of a generated code",
    code = "036-9CF",
    normalized = "0369CF",
    nonce = "e0e8c460a5102d48becf5d5052385e35",
    digest = "2bae838948a2207f6cca5eed73f6e6d6930a6060f207d965ef65007d45f7a8d6",
  },
  {
    label = "lowercase dashed spelling of a generated code",
    code = "036-9cf",
    normalized = "0369CF",
    nonce = "7cbcf7bcf1ebc7b1bdd4667c48e11756",
    digest = "0796ea584a178f9df0f32d0e670729fa97e35c94a18643ef3fe27bce788effc6",
  },
}

return M
