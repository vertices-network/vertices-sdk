#![no_std]
#![forbid(unsafe_code)]

//! Private keys remain behind these traits. Software signing exists only for
//! desktop simulation and tests; production backends are hardware adapters.

#[cfg(feature = "software")]
pub mod software;

use vertices_core::{
    ED25519_SIGNATURE_LEN, Error as CoreError, MAX_SIGNING_BYTES, Observation, ObservationBuilder,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    SigningFailed,
    VerificationFailed,
    Core(CoreError),
}
impl From<CoreError> for Error {
    fn from(value: CoreError) -> Self {
        Self::Core(value)
    }
}

pub trait Ed25519Signer {
    fn public_key(&self) -> [u8; 32];
    fn sign(&self, message: &[u8]) -> Result<[u8; ED25519_SIGNATURE_LEN], Error>;
}

pub trait EvmSigner {
    fn address(&self) -> [u8; 20];
    /// Returns Ethereum's `r || s || y_parity` signature form for a 32-byte digest.
    fn sign_digest(&self, digest: &[u8; 32]) -> Result<[u8; 65], Error>;
}

pub fn sign_observation<const URI: usize, S: Ed25519Signer>(
    signer: &S,
    builder: ObservationBuilder<URI>,
) -> Result<Observation<URI>, Error> {
    let mut bytes = [0; MAX_SIGNING_BYTES];
    let len = builder.signing_bytes(&mut bytes)?;
    Ok(builder.build(signer.sign(&bytes[..len])?))
}

#[cfg(all(test, feature = "software"))]
extern crate std;

#[cfg(all(test, feature = "software"))]
mod tests {
    use super::*;
    use crate::software::SoftwareEd25519Signer;
    use vertices_core::PayloadCodec;
    #[test]
    fn software_signer_produces_verifiable_observation() {
        let signer = SoftwareEd25519Signer::from_seed([42; 32]);
        let builder = ObservationBuilder::<64>::new(
            *b"vertices-device1",
            1,
            1,
            b"payload",
            PayloadCodec { id: 1, version: 1 },
            b"ipfs://payload",
        )
        .unwrap();
        let observation = sign_observation(&signer, builder).unwrap();
        let mut bytes = [0; MAX_SIGNING_BYTES];
        let len = observation.signing_bytes(&mut bytes).unwrap();
        signer
            .verify(&bytes[..len], &observation.signed.signature)
            .unwrap();
    }
}
