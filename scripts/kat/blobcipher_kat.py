# Independent known-answer vector for BlobCipher (Tests/ClipCryptoTests/BlobCipherTests.swift).
# Needs: pip install cryptography. Prints the blob key, then nonce || ciphertext || tag per chunk, as hex.
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ikm = bytes(range(32))
item = "00000000-0000-0000-0000-0000000000B1"
blob = "00000000-0000-0000-0000-0000000000C1"
key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"clip.v1", info=("clip.blob.v1|" + blob).encode()).derive(ikm)
print("key", key.hex())

plaintext = b"0123456789"  # 10 bytes, chunkSize 4 -> chunks "0123", "4567", "89"
chunk_size, count = 4, 3
nonce = bytes(range(12))
for index in (0, 2):
    chunk = plaintext[index * chunk_size:(index + 1) * chunk_size]
    aad = f"clip.blob.v1|{item}|{blob}|{index}|{count}|{len(plaintext)}".encode()
    print("chunk", index, (nonce + AESGCM(key).encrypt(nonce, chunk, aad)).hex())
