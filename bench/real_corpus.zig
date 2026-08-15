pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Exchange = struct {
    request: []const Field,
    response: []const Field,
};

pub const Scenario = struct {
    name: []const u8,
    exchanges: []const Exchange,
};

// Real-world HTTP/2 header captures normalized to lowercase names. Pseudo-fields
// are retained when present in the capture, or derived from the captured
// method/URL/status where the HAR exporter omitted them.
//
// Sources are documented in bench/REAL_CORPUS.md.

const open_bus_req_agencies = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "open-bus-stride-api.hasadna.org.il" },
    .{ .name = ":path", .value = "/gtfs_agencies/list?date_from=2024-02-11" },
    .{ .name = "accept", .value = "*/*" },
    .{ .name = "accept-language", .value = "he-IL" },
    .{ .name = "origin", .value = "http://localhost:3000" },
    .{ .name = "referer", .value = "http://localhost:3000/" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.7727.15 Safari/537.36" },
    .{ .name = "sec-ch-ua", .value = "\"HeadlessChrome\";v=\"147\", \"Not.A/Brand\";v=\"8\", \"Chromium\";v=\"147\"" },
    .{ .name = "sec-ch-ua-mobile", .value = "?0" },
    .{ .name = "sec-ch-ua-platform", .value = "\"Windows\"" },
};

const open_bus_resp_agencies = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "content-length", .value = "8145" },
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "date", .value = "Fri, 29 May 2026 05:28:47 GMT" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includeSubDomains" },
};

const open_bus_req_routes = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "open-bus-stride-api.hasadna.org.il" },
    .{ .name = ":path", .value = "/gtfs_routes/list?limit=100&date_from=2024-02-11&date_to=2024-02-12&operator_refs=3&route_short_name=1" },
    .{ .name = "accept", .value = "*/*" },
    .{ .name = "accept-language", .value = "he-IL" },
    .{ .name = "origin", .value = "http://localhost:3000" },
    .{ .name = "referer", .value = "http://localhost:3000/" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.7727.15 Safari/537.36" },
    .{ .name = "sec-ch-ua", .value = "\"HeadlessChrome\";v=\"147\", \"Not.A/Brand\";v=\"8\", \"Chromium\";v=\"147\"" },
    .{ .name = "sec-ch-ua-mobile", .value = "?0" },
    .{ .name = "sec-ch-ua-platform", .value = "\"Windows\"" },
};

const open_bus_resp_routes = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "content-length", .value = "11001" },
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "date", .value = "Fri, 29 May 2026 05:28:48 GMT" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includeSubDomains" },
};

const open_bus_exchanges = [_]Exchange{
    .{ .request = &open_bus_req_agencies, .response = &open_bus_resp_agencies },
    .{ .request = &open_bus_req_routes, .response = &open_bus_resp_routes },
};

const cslebar_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "www.cslebar.com" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/portfolio/" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "upgrade-insecure-requests", .value = "1" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/78.0.3904.108 Safari/537.36" },
    .{ .name = "sec-fetch-user", .value = "?1" },
    .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3" },
    .{ .name = "sec-fetch-site", .value = "none" },
    .{ .name = "sec-fetch-mode", .value = "navigate" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-language", .value = "en-US,en;q=0.9" },
    .{ .name = "cookie", .value = "_ga=GA1.2.000000000.0000000000; _gid=GA1.2.000000000.0000000000" },
};

const cslebar_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "date", .value = "Sun, 08 Dec 2019 16:23:12 GMT" },
    .{ .name = "server", .value = "Apache" },
    .{ .name = "last-modified", .value = "Sun, 08 Dec 2019 15:42:54 GMT" },
    .{ .name = "etag", .value = "\"29ae-5993321dbfb80\"" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "content-type", .value = "text/html; charset=UTF-8" },
    .{ .name = "vary", .value = "Accept-Encoding" },
    .{ .name = "content-encoding", .value = "gzip" },
    .{ .name = "via", .value = "e4s" },
    .{ .name = "content-length", .value = "1913" },
    .{ .name = "x-dns-prefetch-control", .value = "off" },
};

const cslebar_exchanges = [_]Exchange{.{ .request = &cslebar_req, .response = &cslebar_resp }};

const rubydoc_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "rubydoc.info" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/github/net-ssh/net-ssh" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "upgrade-insecure-requests", .value = "1" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.163 Safari/537.36" },
    .{ .name = "sec-fetch-dest", .value = "document" },
    .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9" },
    .{ .name = "sec-fetch-site", .value = "none" },
    .{ .name = "sec-fetch-mode", .value = "navigate" },
    .{ .name = "sec-fetch-user", .value = "?1" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-language", .value = "en-GB,en-US;q=0.9,en;q=0.8,sv;q=0.7,nb;q=0.6" },
    .{ .name = "cookie", .value = "__cfduid=0000000000000000000000000000000000000000000; _ga=GA1.2.000000000.0000000000; defaultIndex=gems" },
};

const rubydoc_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "date", .value = "Tue, 14 Apr 2020 11:54:34 GMT" },
    .{ .name = "content-type", .value = "text/html" },
    .{ .name = "cache-control", .value = "public, must-revalidate, max-age=60" },
    .{ .name = "last-modified", .value = "Tue, 14 Apr 2020 11:54:26 GMT" },
    .{ .name = "x-xss-protection", .value = "1; mode=block" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-frame-options", .value = "SAMEORIGIN" },
    .{ .name = "cf-cache-status", .value = "DYNAMIC" },
    .{ .name = "expect-ct", .value = "max-age=604800, report-uri=\"https://report-uri.cloudflare.com/cdn-cgi/beacon/expect-ct\"" },
    .{ .name = "server", .value = "cloudflare" },
    .{ .name = "cf-ray", .value = "583d3b324eb5d875-CPH" },
    .{ .name = "content-encoding", .value = "br" },
};

const rubydoc_exchanges = [_]Exchange{.{ .request = &rubydoc_req, .response = &rubydoc_resp }};

const twitter_font_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "abs.twimg.com" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/a/1508919822/font/edge-icons-Regular.woff" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "origin", .value = "https://twitter.com" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-language", .value = "en-US,en;q=0.8" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.100 Safari/537.36" },
    .{ .name = "accept", .value = "*/*" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "referer", .value = "https://abs.twimg.com/a/1508919822/css/t1/twitter_core.bundle.css" },
};

const twitter_font_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "date", .value = "Thu, 26 Oct 2017 01:14:33 GMT" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-cdn", .value = "FAST" },
    .{ .name = "x-ton-expected-size", .value = "34292" },
    .{ .name = "x-cache", .value = "HIT" },
    .{ .name = "content-length", .value = "34292" },
    .{ .name = "x-served-by", .value = "cache-tw-sjc1-cr1-21-TWSJC1" },
    .{ .name = "x-response-time", .value = "9" },
    .{ .name = "last-modified", .value = "Wed, 25 Oct 2017 08:42:36 GMT" },
    .{ .name = "etag", .value = "\"zg6Odo0rIHaTZ2vMRfm8yA==\"" },
    .{ .name = "content-type", .value = "application/font-woff" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "x-connection-hash", .value = "9f100bce40d930d1d00a7595bcd62352" },
    .{ .name = "accept-ranges", .value = "bytes" },
};

const twitter_font_exchanges = [_]Exchange{.{ .request = &twitter_font_req, .response = &twitter_font_resp }};

const twitter_animation_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "abs.twimg.com" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/a/1508919822/img/animations/web_heart_animation_edge.png" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-language", .value = "en-US,en;q=0.8" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.100 Safari/537.36" },
    .{ .name = "accept", .value = "image/webp,image/apng,image/*,*/*;q=0.8" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "referer", .value = "https://abs.twimg.com/a/1508919822/css/t1/twitter_core.bundle.css" },
};

const twitter_animation_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "date", .value = "Thu, 26 Oct 2017 01:14:33 GMT" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-cdn", .value = "FAST" },
    .{ .name = "x-ton-expected-size", .value = "22711" },
    .{ .name = "x-cache", .value = "HIT" },
    .{ .name = "content-length", .value = "22711" },
    .{ .name = "x-served-by", .value = "cache-tw-sjc1-cr1-11-TWSJC1" },
    .{ .name = "x-response-time", .value = "111" },
    .{ .name = "last-modified", .value = "Wed, 25 Oct 2017 08:42:36 GMT" },
    .{ .name = "etag", .value = "\"PFUockkwG7QJek17rLbmBw==\"" },
    .{ .name = "content-type", .value = "image/png" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "x-connection-hash", .value = "6658ef2ab05f34c0cb7ad8142f2a0247" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "expires", .value = "Thu, 25 Oct 2018 10:18:08 GMT" },
};

const twitter_spinner_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "abs.twimg.com" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/a/1508919822/img/t1/spinners/spinner-rosetta-gray-32x32.gif" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-language", .value = "en-US,en;q=0.8" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.100 Safari/537.36" },
    .{ .name = "accept", .value = "image/webp,image/apng,image/*,*/*;q=0.8" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "referer", .value = "https://abs.twimg.com/a/1508919822/css/t1/twitter_core.bundle.css" },
};

const twitter_spinner_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "x-response-time", .value = "8" },
    .{ .name = "date", .value = "Thu, 26 Oct 2017 01:14:33 GMT" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "last-modified", .value = "Wed, 25 Oct 2017 08:42:37 GMT" },
    .{ .name = "x-cdn", .value = "FAST" },
    .{ .name = "etag", .value = "\"5whCzDLCK60aJAgJOf7p5A==\"" },
    .{ .name = "x-ton-expected-size", .value = "10947" },
    .{ .name = "x-cache", .value = "HIT" },
    .{ .name = "content-type", .value = "image/gif" },
    .{ .name = "expires", .value = "Thu, 25 Oct 2018 10:18:08 GMT" },
    .{ .name = "x-connection-hash", .value = "ce9439d6543c205d659c27d3f436fa09" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "content-length", .value = "10947" },
    .{ .name = "x-served-by", .value = "cache-tw-sjc1-cr1-11-TWSJC1" },
};

const twitter_emoji1_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "abs.twimg.com" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/emoji/v2/72x72/26a1.png" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-language", .value = "en-US,en;q=0.8" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.100 Safari/537.36" },
    .{ .name = "accept", .value = "image/webp,image/apng,image/*,*/*;q=0.8" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "referer", .value = "https://twitter.com/DataToViz?ref_src=twsrc%5Egoogle%7Ctwcamp%5Eserp%7Ctwgr%5Eauthor" },
};

const twitter_emoji1_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "date", .value = "Thu, 26 Oct 2017 01:14:33 GMT" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-cdn", .value = "FAST" },
    .{ .name = "x-ton-expected-size", .value = "753" },
    .{ .name = "x-cache", .value = "HIT" },
    .{ .name = "content-length", .value = "753" },
    .{ .name = "x-served-by", .value = "cache-tw-sjc1-cr1-11-TWSJC1" },
    .{ .name = "x-response-time", .value = "32" },
    .{ .name = "last-modified", .value = "Tue, 02 Aug 2016 12:57:47 GMT" },
    .{ .name = "etag", .value = "\"BRB2XPCGO9mj8ip54JgFJg==\"" },
    .{ .name = "content-type", .value = "image/png" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "x-connection-hash", .value = "c36fd440a5263b0f2c8cb4f89135170c" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "expires", .value = "Fri, 11 Aug 2017 06:30:37 GMT" },
};

const twitter_emoji2_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "abs.twimg.com" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/emoji/v2/72x72/1f9d0.png" },
    .{ .name = "pragma", .value = "no-cache" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-language", .value = "en-US,en;q=0.8" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.100 Safari/537.36" },
    .{ .name = "accept", .value = "image/webp,image/apng,image/*,*/*;q=0.8" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "referer", .value = "https://twitter.com/DataToViz?ref_src=twsrc%5Egoogle%7Ctwcamp%5Eserp%7Ctwgr%5Eauthor" },
};

const twitter_emoji2_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "date", .value = "Thu, 26 Oct 2017 01:14:33 GMT" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-cdn", .value = "FAST" },
    .{ .name = "x-ton-expected-size", .value = "1112" },
    .{ .name = "x-cache", .value = "HIT" },
    .{ .name = "content-length", .value = "1112" },
    .{ .name = "x-served-by", .value = "cache-tw-sjc1-cr1-11-TWSJC1" },
    .{ .name = "x-response-time", .value = "52" },
    .{ .name = "last-modified", .value = "Mon, 22 May 2017 17:44:51 GMT" },
    .{ .name = "etag", .value = "\"gdgYe0dfhKuJmk6cQTKJZA==\"" },
    .{ .name = "content-type", .value = "image/png" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "x-connection-hash", .value = "3fa531b1d9e16c0c8039e34dc24bdb5f" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "expires", .value = "Wed, 23 May 2018 11:36:12 GMT" },
};

const twitter_media_exchanges = [_]Exchange{
    .{ .request = &twitter_animation_req, .response = &twitter_animation_resp },
    .{ .request = &twitter_spinner_req, .response = &twitter_spinner_resp },
    .{ .request = &twitter_emoji1_req, .response = &twitter_emoji1_resp },
    .{ .request = &twitter_emoji2_req, .response = &twitter_emoji2_resp },
};

const google_css_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "fonts.googleapis.com" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/css?family=Arimo:400,700" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36" },
    .{ .name = "accept", .value = "text/css,*/*;q=0.1" },
    .{ .name = "sec-fetch-site", .value = "cross-site" },
    .{ .name = "sec-fetch-mode", .value = "no-cors" },
    .{ .name = "sec-fetch-dest", .value = "style" },
    .{ .name = "referer", .value = "http://localhost:8080/" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .name = "accept-language", .value = "en-US,en;q=0.9" },
    .{ .name = "if-modified-since", .value = "Tue, 04 Jan 2022 01:12:18 GMT" },
};

const google_css_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "content-type", .value = "text/css; charset=utf-8" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "timing-allow-origin", .value = "*" },
    .{ .name = "link", .value = "<https://fonts.gstatic.com>; rel=preconnect; crossorigin" },
    .{ .name = "expires", .value = "Thu, 06 Jan 2022 11:49:37 GMT" },
    .{ .name = "date", .value = "Thu, 06 Jan 2022 11:49:37 GMT" },
    .{ .name = "cache-control", .value = "private, max-age=86400, stale-while-revalidate=604800" },
    .{ .name = "last-modified", .value = "Thu, 06 Jan 2022 11:20:42 GMT" },
    .{ .name = "cross-origin-resource-policy", .value = "cross-origin" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin-allow-popups" },
    .{ .name = "content-encoding", .value = "gzip" },
    .{ .name = "server", .value = "ESF" },
    .{ .name = "x-xss-protection", .value = "0" },
    .{ .name = "x-frame-options", .value = "SAMEORIGIN" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "alt-svc", .value = "h3=\":443\"; ma=2592000,h3-29=\":443\"; ma=2592000,h3-Q050=\":443\"; ma=2592000,h3-Q046=\":443\"; ma=2592000,h3-Q043=\":443\"; ma=2592000,quic=\":443\"; ma=2592000; v=\"46,43\"" },
};

const google_font_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":authority", .value = "fonts.gstatic.com" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/s/arimo/v17/P5sMzZCDf9_T_10ZxCE.woff2" },
    .{ .name = "sec-ch-ua", .value = "\" Not A;Brand\";v=\"99\", \"Chromium\";v=\"96\", \"Google Chrome\";v=\"96\"" },
    .{ .name = "referer", .value = "https://fonts.googleapis.com/" },
    .{ .name = "origin", .value = "http://localhost:8080" },
    .{ .name = "sec-ch-ua-mobile", .value = "?0" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36" },
    .{ .name = "sec-ch-ua-platform", .value = "\"Linux\"" },
};

const google_font_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "content-type", .value = "font/woff2" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "cache-control", .value = "public, max-age=31536000" },
};

const google_css_exchanges = [_]Exchange{.{ .request = &google_css_req, .response = &google_css_resp }};
const google_font_exchanges = [_]Exchange{.{ .request = &google_font_req, .response = &google_font_resp }};

const pypi_path = "/packages/00/e5/f12a80907d0884e6dff9c16d0c0114d81b8cd07dc3ae54c5e962cc83037e/tqdm-4.66.1-py3-none-any.whl";

const pypi_head_req = [_]Field{
    .{ .name = ":method", .value = "HEAD" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "files.pythonhosted.org" },
    .{ .name = ":path", .value = pypi_path },
    .{ .name = "accept", .value = "*/*" },
    .{ .name = "user-agent", .value = "puffin" },
    .{ .name = "accept-encoding", .value = "gzip, br" },
};

const pypi_head_resp = [_]Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "last-modified", .value = "Thu, 10 Aug 2023 12:02:26 GMT" },
    .{ .name = "etag", .value = "\"a296c6e224c118b0d08cd77e8c08f4b1\"" },
    .{ .name = "x-amz-request-id", .value = "aeb4d3335548af85" },
    .{ .name = "x-amz-id-2", .value = "aN65jxTFgNrlm8zEJMNdk7mYLYwUwTzh0" },
    .{ .name = "x-amz-version-id", .value = "4_z179c51e67f11a0ad8f6c0018_f10789ff3151435c8_d20230810_m113900_c005_v0501001_t0045_u01691667540984" },
    .{ .name = "content-type", .value = "application/octet-stream" },
    .{ .name = "cache-control", .value = "max-age=365000000, immutable, public" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "date", .value = "Tue, 12 Dec 2023 05:46:53 GMT" },
    .{ .name = "age", .value = "2295687" },
    .{ .name = "x-served-by", .value = "cache-iad-kcgs7200038-IAD, cache-stp9222-STP" },
    .{ .name = "x-cache", .value = "HIT, HIT" },
    .{ .name = "x-cache-hits", .value = "21458, 104163" },
    .{ .name = "x-timer", .value = "S1702358607.425873,VS0,VE0" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includeSubDomains; preload" },
    .{ .name = "x-frame-options", .value = "deny" },
    .{ .name = "x-xss-protection", .value = "1; mode=block" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-permitted-cross-domain-policies", .value = "none" },
    .{ .name = "x-robots-header", .value = "noindex" },
    .{ .name = "x-pypi-file-python-version", .value = "py3" },
    .{ .name = "x-pypi-file-version", .value = "4.66.1" },
    .{ .name = "x-pypi-file-package-type", .value = "bdist_wheel" },
    .{ .name = "x-pypi-file-project", .value = "tqdm" },
    .{ .name = "content-length", .value = "78258" },
};

const pypi_get1_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "files.pythonhosted.org" },
    .{ .name = ":path", .value = pypi_path },
    .{ .name = "range", .value = "bytes=61874-78257" },
    .{ .name = "accept", .value = "*/*" },
    .{ .name = "user-agent", .value = "puffin" },
};

const pypi_get1_resp = [_]Field{
    .{ .name = ":status", .value = "206" },
    .{ .name = "last-modified", .value = "Thu, 10 Aug 2023 12:02:26 GMT" },
    .{ .name = "etag", .value = "\"a296c6e224c118b0d08cd77e8c08f4b1\"" },
    .{ .name = "x-amz-request-id", .value = "aeb4d3335548af85" },
    .{ .name = "x-amz-id-2", .value = "aN65jxTFgNrlm8zEJMNdk7mYLYwUwTzh0" },
    .{ .name = "x-amz-version-id", .value = "4_z179c51e67f11a0ad8f6c0018_f10789ff3151435c8_d20230810_m113900_c005_v0501001_t0045_u01691667540984" },
    .{ .name = "content-type", .value = "application/octet-stream" },
    .{ .name = "cache-control", .value = "max-age=365000000, immutable, public" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "date", .value = "Tue, 12 Dec 2023 05:46:53 GMT" },
    .{ .name = "age", .value = "2295687" },
    .{ .name = "x-served-by", .value = "cache-iad-kcgs7200038-IAD, cache-stp9222-STP" },
    .{ .name = "x-cache", .value = "HIT, HIT" },
    .{ .name = "x-cache-hits", .value = "21458, 104164" },
    .{ .name = "x-timer", .value = "S1702358607.435964,VS0,VE0" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includeSubDomains; preload" },
    .{ .name = "x-frame-options", .value = "deny" },
    .{ .name = "x-xss-protection", .value = "1; mode=block" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-robots-header", .value = "noindex" },
    .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Range" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "x-pypi-file-python-version", .value = "py3" },
    .{ .name = "x-pypi-file-version", .value = "4.66.1" },
    .{ .name = "x-pypi-file-package-type", .value = "bdist_wheel" },
    .{ .name = "x-pypi-file-project", .value = "tqdm" },
    .{ .name = "content-range", .value = "bytes 61874-78257/78258" },
    .{ .name = "content-length", .value = "16384" },
};

const pypi_get2_req = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "files.pythonhosted.org" },
    .{ .name = ":path", .value = pypi_path },
    .{ .name = "range", .value = "bytes=55094-61873" },
    .{ .name = "accept", .value = "*/*" },
    .{ .name = "user-agent", .value = "puffin" },
};

const pypi_get2_resp = [_]Field{
    .{ .name = ":status", .value = "206" },
    .{ .name = "last-modified", .value = "Thu, 10 Aug 2023 12:02:26 GMT" },
    .{ .name = "etag", .value = "\"a296c6e224c118b0d08cd77e8c08f4b1\"" },
    .{ .name = "x-amz-request-id", .value = "aeb4d3335548af85" },
    .{ .name = "x-amz-id-2", .value = "aN65jxTFgNrlm8zEJMNdk7mYLYwUwTzh0" },
    .{ .name = "x-amz-version-id", .value = "4_z179c51e67f11a0ad8f6c0018_f10789ff3151435c8_d20230810_m113900_c005_v0501001_t0045_u01691667540984" },
    .{ .name = "content-type", .value = "application/octet-stream" },
    .{ .name = "cache-control", .value = "max-age=365000000, immutable, public" },
    .{ .name = "accept-ranges", .value = "bytes" },
    .{ .name = "date", .value = "Tue, 12 Dec 2023 05:46:53 GMT" },
    .{ .name = "age", .value = "2295687" },
    .{ .name = "x-served-by", .value = "cache-iad-kcgs7200038-IAD, cache-stp9222-STP" },
    .{ .name = "x-cache", .value = "HIT, HIT" },
    .{ .name = "x-cache-hits", .value = "21458, 104165" },
    .{ .name = "x-timer", .value = "S1702358607.454024,VS0,VE0" },
    .{ .name = "strict-transport-security", .value = "max-age=31536000; includeSubDomains; preload" },
    .{ .name = "x-frame-options", .value = "deny" },
    .{ .name = "x-xss-protection", .value = "1; mode=block" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-robots-header", .value = "noindex" },
    .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "Range" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "x-pypi-file-python-version", .value = "py3" },
    .{ .name = "x-pypi-file-version", .value = "4.66.1" },
    .{ .name = "x-pypi-file-package-type", .value = "bdist_wheel" },
    .{ .name = "x-pypi-file-project", .value = "tqdm" },
    .{ .name = "content-range", .value = "bytes 55094-61873/78258" },
    .{ .name = "content-length", .value = "6780" },
};

const pypi_exchanges = [_]Exchange{
    .{ .request = &pypi_head_req, .response = &pypi_head_resp },
    .{ .request = &pypi_get1_req, .response = &pypi_get1_resp },
    .{ .request = &pypi_get2_req, .response = &pypi_get2_resp },
};

pub const scenarios = [_]Scenario{
    .{ .name = "open-bus API (Chromium)", .exchanges = &open_bus_exchanges },
    .{ .name = "HTML navigation (cslebar)", .exchanges = &cslebar_exchanges },
    .{ .name = "HTML + Cloudflare (rubydoc)", .exchanges = &rubydoc_exchanges },
    .{ .name = "Twitter CDN font", .exchanges = &twitter_font_exchanges },
    .{ .name = "Twitter CDN media connection", .exchanges = &twitter_media_exchanges },
    .{ .name = "Google Fonts CSS", .exchanges = &google_css_exchanges },
    .{ .name = "Google Fonts asset", .exchanges = &google_font_exchanges },
    .{ .name = "PyPI HEAD + range GET", .exchanges = &pypi_exchanges },
};

pub fn fieldCount(block: []const Field) usize {
    return block.len;
}

pub fn payloadBytes(block: []const Field) usize {
    var total: usize = 0;
    for (block) |f| total += f.name.len + f.value.len;
    return total;
}
