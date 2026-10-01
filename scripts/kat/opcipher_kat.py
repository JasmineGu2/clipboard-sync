# Independent known-answer vector for OpCipher (Tests/ClipCryptoTests/KnownAnswerTests.swift).
# Needs: pip install cryptography. Prints nonce || ciphertext || tag as hex.
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ikm = bytes(range(32))
dk = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"clip.v1", info=b"clip.data.v1").derive(ikm)
assert dk.hex() == "9465a96eb24eb872e7e5cb56ca56db2315114376732c30cd5078e7607708deb7"
pt = b'{"id":{"rawValue":"00000000-0000-0000-0000-0000000000A1"},"itemID":{"rawValue":"00000000-0000-0000-0000-0000000000B1"},"kind":{"create":{"_0":{"createdAt":1790000000000,"kind":"text","sourceDevice":{"rawValue":"00000000-0000-0000-0000-0000000000D1"},"sourceDeviceName":"PC","text":"hello"}}},"timestamp":{"counter":7,"device":{"rawValue":"00000000-0000-0000-0000-0000000000D1"},"wallMillis":1790000000000}}'
nonce = bytes(range(12))
aad = b"clip.op.v1|00000000-0000-0000-0000-0000000000B1|00000000-0000-0000-0000-0000000000A1"
combined = (nonce + AESGCM(dk).encrypt(nonce, pt, aad)).hex()
assert combined.endswith("92507dac7"), "vector drifted"
print(combined)
