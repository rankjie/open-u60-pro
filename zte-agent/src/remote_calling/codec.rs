pub fn encode(sample: i16) -> u8 {
    let sign = if sample < 0 { 0x80 } else { 0 };
    let value = (i32::from(sample).abs().min(32635) + 132) as u32;
    let exponent = (31 - value.leading_zeros()).saturating_sub(7).min(7);
    let mantissa = (value >> (exponent + 3)) & 0xf;
    !(sign | (exponent as u8) << 4 | mantissa as u8)
}

pub fn decode(byte: u8) -> i16 {
    let value = !byte;
    let magnitude = (((i32::from(value & 0xf) << 3) + 132) << ((value >> 4) & 7)) - 132;
    if value & 0x80 != 0 {
        -magnitude as i16
    } else {
        magnitude as i16
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn g711_reference_values_and_saturation() {
        for (pcm, ulaw) in [
            (0, 0xff),
            (1, 0xff),
            (-1, 0x7f),
            (1000, 0xce),
            (-1000, 0x4e),
            (i16::MAX, 0x80),
            (i16::MIN, 0x00),
        ] {
            assert_eq!(encode(pcm), ulaw);
        }
        assert_eq!(decode(0xff), 0);
        assert_eq!(decode(0x7f), 0);
        assert_eq!(decode(0x80), 32124);
        assert_eq!(decode(0), -32124);
    }
    #[test]
    fn the_entire_pcm_domain_stays_within_g711_quantization_error() {
        for sample in i16::MIN..=i16::MAX {
            let recovered = decode(encode(sample));
            assert!((i32::from(sample) - i32::from(recovered)).abs() <= 644);
        }
    }
}
