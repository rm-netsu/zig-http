pub const huffman = @import("hpack/huffman.zig");
pub const static = @import("hpack/static.zig");
pub const table = @import("hpack/table.zig");
pub const codec = @import("hpack/codec.zig");

pub const Decoder = codec.Decoder;
pub const Encoder = codec.Encoder;
pub const Indexing = codec.Indexing;
pub const HuffmanMode = codec.HuffmanMode;

test {
    _ = huffman;
    _ = static;
    _ = table;
    _ = codec;
}
