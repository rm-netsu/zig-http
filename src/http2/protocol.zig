pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
    _,
};

pub fn clientInitiated(stream_id: u31) bool {
    return stream_id != 0 and (stream_id & 1) == 1;
}

pub fn serverInitiated(stream_id: u31) bool {
    return stream_id != 0 and (stream_id & 1) == 0;
}
