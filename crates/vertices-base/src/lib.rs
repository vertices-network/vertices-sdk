#![no_std]
#![forbid(unsafe_code)]

//! Base-specific ABI and EIP-1559 support is added after the core
//! envelope vectors are stable.

pub trait RpcTransport {
    type Error;
    fn post_json(&mut self, request: &[u8], response: &mut [u8]) -> Result<usize, Self::Error>;
}
