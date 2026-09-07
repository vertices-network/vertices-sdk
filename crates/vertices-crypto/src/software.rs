use super::*;
use ed25519_dalek::{Signature, SigningKey, VerifyingKey};
use ed25519_dalek::{Signer, Verifier};

/// Test-only signer. Never enable this feature in device firmware.
pub struct SoftwareEd25519Signer(SigningKey);
impl SoftwareEd25519Signer {
    pub fn from_seed(seed: [u8; 32]) -> Self {
        Self(SigningKey::from_bytes(&seed))
    }
    pub fn verify(&self, message: &[u8], signature: &[u8; 64]) -> Result<(), Error> {
        let signature = Signature::from_bytes(signature);
        self.0
            .verifying_key()
            .verify(message, &signature)
            .map_err(|_| Error::VerificationFailed)
    }
    pub fn verifying_key(&self) -> VerifyingKey {
        self.0.verifying_key()
    }
}

impl Ed25519Signer for SoftwareEd25519Signer {
    fn public_key(&self) -> [u8; 32] {
        self.0.verifying_key().to_bytes()
    }
    fn sign(&self, message: &[u8]) -> Result<[u8; 64], Error> {
        Ok(self.0.sign(message).to_bytes())
    }
}
