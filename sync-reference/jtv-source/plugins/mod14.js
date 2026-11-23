// =============================================================================
// TorrentHub v1.0.0 — tab Torrent 18+ for JTV (written 2026-11-16).
//
// Two lanes, one plugin:
//   Lane B (modern): the public adult Stremio addon at ADDON_BASE —
//     TPDB scene browser, 4K/1080p rails, JAV studio rails. Its meta
//     and stream endpoints speak the Stremio JSON shapes; streams
//     come back as bare infoHashes.
//   Lane A (classics): Cinemeta meta + Torrentio streams, keyed by
//     IMDb id — the same stack the TV apps use. Region rails are a
//     CURATED list embedded below (63 titles, every id verified
//     against Cinemeta meta by name + country + poster before it
//     was admitted; Cinemeta's own Adult catalogue holds only 9).
//
// Playback contract: every torrent stream becomes an episode whose
// id is "jtvhash:<infoHash>". The APP intercepts that prefix in
// MovieService.resolveEpisode and hands the hash to its native
// debrid resolver (Real-Debrid primary, TorBox fallback; tokens
// live in the app, never in this plugin). Direct-url streams from
// the addon (tube sources) keep their URL as the episode id and
// play through the normal direct-media path.
//
// Detail is two-stage: parseMovieDetail on a META payload returns
// the full record plus ONE placeholder episode "jtvstreams:<id>";
// the app detects the prefix, fetches the streams payload through
// getUrlDetail, and replaces the server list with the episodes
// parsed from it. Parsers tell payloads apart by shape (.meta vs
// .streams) and host (pageUrl).
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "torrenthub",
        "name": "Torrent 18+",
        "version": "1.0.7",
        "baseUrl": "https://addon.debrid.in",
        "iconUrl": "https://raw.githubusercontent.com/zjoenguyenz/jtv-source/main/icons/mod14.png",
        "isEnabled": true,
        "isAdult": true,
        "type": "VIDEO",
        "playerType": "native",
        "layoutType": "HORIZONTAL"
    });
}

var ADDON_BASE = "https://addon.debrid.in";
var CINEMETA = "https://v3-cinemeta.strem.io";
var TORRENTIO = "https://torrentio.strem.fun";
var ADDON_TYPE = "Porn";

var CURATED = {"us":[{"i":"tt0081593","t":"Taboo","y":1980,"p":"https://images.metahub.space/poster/small/tt0081593/img","b":"https://images.metahub.space/background/medium/tt0081593/img"},{"i":"tt0083707","t":"Café Flesh","y":1982,"p":"https://live.metahub.space/poster/small/tt0083707/img","b":"https://live.metahub.space/background/medium/tt0083707/img"},{"i":"tt0127862","t":"SexWorld","y":1978,"p":"https://live.metahub.space/poster/small/tt0127862/img","b":"https://live.metahub.space/background/medium/tt0127862/img"},{"i":"tt0477457","t":"Pirates","y":2005,"p":"https://images.metahub.space/poster/small/tt0477457/img","b":"https://images.metahub.space/background/medium/tt0477457/img"},{"i":"tt0073589","t":"The Image","y":1975,"p":"https://images.metahub.space/poster/small/tt0073589/img","b":"https://images.metahub.space/background/medium/tt0073589/img"},{"i":"tt0074113","t":"Alice in Wonderland: An X-Rated Musical Fantasy","y":1976,"p":"https://images.metahub.space/poster/small/tt0074113/img","b":"https://images.metahub.space/background/medium/tt0074113/img"},{"i":"tt0178845","t":"Private Teacher","y":1983,"p":"https://images.metahub.space/poster/small/tt0178845/img","b":"https://images.metahub.space/background/medium/tt0178845/img"}],"eu":[{"i":"tt0061395","t":"Belle de Jour","y":1968,"p":"https://images.metahub.space/poster/small/tt0061395/img","b":"https://images.metahub.space/background/medium/tt0061395/img"},{"i":"tt0070849","t":"Last Tango in Paris","y":1973,"p":"https://images.metahub.space/poster/small/tt0070849/img","b":"https://images.metahub.space/background/medium/tt0070849/img"},{"i":"tt0071359","t":"Immoral Tales","y":1974,"p":"https://images.metahub.space/poster/small/tt0071359/img","b":"https://images.metahub.space/background/medium/tt0071359/img"},{"i":"tt0073115","t":"The Story of O","y":1975,"p":"https://images.metahub.space/poster/small/tt0073115/img","b":"https://images.metahub.space/background/medium/tt0073115/img"},{"i":"tt0075753","t":"Bilitis","y":1977,"p":"https://images.metahub.space/poster/small/tt0075753/img","b":"https://images.metahub.space/background/medium/tt0075753/img"},{"i":"tt0076347","t":"Madame Claude","y":1977,"p":"https://images.metahub.space/poster/small/tt0076347/img","b":"https://images.metahub.space/background/medium/tt0076347/img"},{"i":"tt0075163","t":"Madam Kitty","y":1976,"p":"https://images.metahub.space/poster/small/tt0075163/img","b":"https://images.metahub.space/background/medium/tt0075163/img"},{"i":"tt0080491","t":"Caligula","y":1980,"p":"https://images.metahub.space/poster/small/tt0080491/img","b":"https://images.metahub.space/background/medium/tt0080491/img"},{"i":"tt0085328","t":"The Key","y":1983,"p":"https://images.metahub.space/poster/small/tt0085328/img","b":"https://images.metahub.space/background/medium/tt0085328/img"},{"i":"tt0098063","t":"Paprika","y":1991,"p":"https://images.metahub.space/poster/small/tt0098063/img","b":"https://images.metahub.space/background/medium/tt0098063/img"},{"i":"tt0071464","t":"Emmanuelle","y":1974,"p":"https://images.metahub.space/poster/small/tt0071464/img","b":"https://images.metahub.space/background/medium/tt0071464/img"},{"i":"tt0072933","t":"Emmanuelle II","y":1975,"p":"https://images.metahub.space/poster/small/tt0072933/img","b":"https://images.metahub.space/background/medium/tt0072933/img"},{"i":"tt0079135","t":"Fascination","y":1980,"p":"https://images.metahub.space/poster/small/tt0079135/img","b":"https://images.metahub.space/background/medium/tt0079135/img"},{"i":"tt0075984","t":"Emanuelle and the Last Cannibals","y":1977,"p":"https://images.metahub.space/poster/small/tt0075984/img","b":"https://images.metahub.space/background/medium/tt0075984/img"},{"i":"tt0065981","t":"The Lickerish Quartet","y":1970,"p":"https://images.metahub.space/poster/small/tt0065981/img","b":"https://images.metahub.space/background/medium/tt0065981/img"},{"i":"tt0063683","t":"Therese and Isabelle","y":1968,"p":"https://images.metahub.space/poster/small/tt0063683/img","b":"https://images.metahub.space/background/medium/tt0063683/img"},{"i":"tt0110214","t":"Tharzan - La vera storia del figlio della giungla","y":1995,"p":"https://images.metahub.space/poster/small/tt0110214/img","b":"https://images.metahub.space/background/medium/tt0110214/img"},{"i":"tt0077497","t":"Emmanuelle 3","y":1977,"p":"https://images.metahub.space/poster/small/tt0077497/img","b":"https://images.metahub.space/background/medium/tt0077497/img"}],"jp":[{"i":"tt0074102","t":"In the Realm of the Senses","y":1977,"p":"https://images.metahub.space/poster/small/tt0074102/img","b":"https://images.metahub.space/background/medium/tt0074102/img"},{"i":"tt0073208","t":"A Woman Called Sada Abe","y":1975,"p":"https://images.metahub.space/poster/small/tt0073208/img","b":"https://images.metahub.space/background/medium/tt0073208/img"},{"i":"tt0225920","t":"Flower and Snake","y":1974,"p":"https://images.metahub.space/poster/small/tt0225920/img","b":"https://images.metahub.space/background/medium/tt0225920/img"},{"i":"tt0228419","t":"Wife to Be Sacrificed","y":1974,"p":"https://images.metahub.space/poster/small/tt0228419/img","b":"https://images.metahub.space/background/medium/tt0228419/img"},{"i":"tt0072430","t":"World of Geisha","y":1973,"p":"https://images.metahub.space/poster/small/tt0072430/img","b":"https://images.metahub.space/background/medium/tt0072430/img"},{"i":"tt0220570","t":"Ichijo's Wet Lust","y":1972,"p":"https://images.metahub.space/poster/small/tt0220570/img","b":"https://images.metahub.space/background/medium/tt0220570/img"},{"i":"tt0287685","t":"Sex Rider: Wet Highway","y":1971,"p":"https://images.metahub.space/poster/small/tt0287685/img","b":"https://images.metahub.space/background/medium/tt0287685/img"},{"i":"tt0228255","t":"The Watcher in the Attic","y":1976,"p":"https://live.metahub.space/poster/small/tt0228255/img","b":"https://live.metahub.space/background/medium/tt0228255/img"},{"i":"tt0226267","t":"Fairy in a Cage","y":1977,"p":"https://images.metahub.space/poster/small/tt0226267/img","b":"https://images.metahub.space/background/medium/tt0226267/img"},{"i":"tt0201716","t":"Inflatable Sex Doll of the Wastelands","y":1967,"p":"https://live.metahub.space/poster/small/tt0201716/img","b":"https://live.metahub.space/background/medium/tt0201716/img"},{"i":"tt0065233","t":"Go, Go Second Time Virgin","y":1969,"p":"https://images.metahub.space/poster/small/tt0065233/img","b":"https://images.metahub.space/background/medium/tt0065233/img"}],"hk":[{"i":"tt0100014","t":"Erotic Ghost Story","y":1990,"p":"https://images.metahub.space/poster/small/tt0100014/img","b":"https://images.metahub.space/background/medium/tt0100014/img"},{"i":"tt0102296","t":"Erotic Ghost Story II","y":1991,"p":"https://images.metahub.space/poster/small/tt0102296/img","b":"https://images.metahub.space/background/medium/tt0102296/img"},{"i":"tt0109412","t":"Naked Killer","y":1995,"p":"https://images.metahub.space/poster/small/tt0109412/img","b":"https://images.metahub.space/background/medium/tt0109412/img"},{"i":"tt0107572","t":"Daughter of Darkness","y":1993,"p":"https://images.metahub.space/poster/small/tt0107572/img","b":"https://images.metahub.space/background/medium/tt0107572/img"},{"i":"tt0167945","t":"Fruit Is Swelling","y":1997,"p":"https://images.metahub.space/poster/small/tt0167945/img","b":"https://images.metahub.space/background/medium/tt0167945/img"},{"i":"tt0113757","t":"A Chinese Torture Chamber Story","y":1994,"p":"https://images.metahub.space/poster/small/tt0113757/img","b":"https://images.metahub.space/background/medium/tt0113757/img"},{"i":"tt0110927","t":"Ancient Chinese Whorehouse","y":1994,"p":"https://images.metahub.space/poster/small/tt0110927/img","b":"https://images.metahub.space/background/medium/tt0110927/img"},{"i":"tt0068744","t":"Intimate Confessions of a Chinese Courtesan","y":1972,"p":"https://images.metahub.space/poster/small/tt0068744/img","b":"https://images.metahub.space/background/medium/tt0068744/img"},{"i":"tt0105287","t":"Sex and Zen","y":1991,"p":"https://images.metahub.space/poster/small/tt0105287/img","b":"https://images.metahub.space/background/medium/tt0105287/img"},{"i":"tt0117605","t":"Sex and Zen II","y":1996,"p":"https://images.metahub.space/poster/small/tt0117605/img","b":"https://images.metahub.space/background/medium/tt0117605/img"},{"i":"tt0133196","t":"Sex and Zen III","y":1998,"p":"https://images.metahub.space/poster/small/tt0133196/img","b":"https://images.metahub.space/background/medium/tt0133196/img"},{"i":"tt1365048","t":"3-D Sex and Zen: Extreme Ecstasy","y":2011,"p":"https://images.metahub.space/poster/small/tt1365048/img","b":"https://images.metahub.space/background/medium/tt1365048/img"}],"kr":[{"i":"tt4016934","t":"The Handmaiden","y":2017,"p":"https://images.metahub.space/poster/small/tt4016934/img","b":"https://images.metahub.space/background/medium/tt4016934/img"},{"i":"tt2390253","t":"A Muse","y":2012,"p":"https://images.metahub.space/poster/small/tt2390253/img","b":"https://images.metahub.space/background/medium/tt2390253/img"},{"i":"tt2544120","t":"The Concubine","y":2012,"p":"https://images.metahub.space/poster/small/tt2544120/img","b":"https://images.metahub.space/background/medium/tt2544120/img"},{"i":"tt3303730","t":"Obsessed","y":2014,"p":"https://images.metahub.space/poster/small/tt3303730/img","b":"https://images.metahub.space/background/medium/tt3303730/img"},{"i":"tt1314652","t":"The Housemaid","y":2011,"p":"https://images.metahub.space/poster/small/tt1314652/img","b":"https://images.metahub.space/background/medium/tt1314652/img"},{"i":"tt1155053","t":"A Frozen Flower","y":2008,"p":"https://images.metahub.space/poster/small/tt1155053/img","b":"https://images.metahub.space/background/medium/tt1155053/img"},{"i":"tt0427411","t":"The Scarlet Letter","y":2004,"p":"https://images.metahub.space/poster/small/tt0427411/img","b":"https://images.metahub.space/background/medium/tt0427411/img"},{"i":"tt0436639","t":"Green Chair","y":2005,"p":"https://images.metahub.space/poster/small/tt0436639/img","b":"https://images.metahub.space/background/medium/tt0436639/img"},{"i":"tt2106670","t":"The Taste of Money","y":2013,"p":"https://images.metahub.space/poster/small/tt2106670/img","b":"https://images.metahub.space/background/medium/tt2106670/img"},{"i":"tt3958014","t":"Scarlet Innocence","y":2017,"p":"https://images.metahub.space/poster/small/tt3958014/img","b":"https://images.metahub.space/background/medium/tt3958014/img"},{"i":"tt5700648","t":"A Man and a Woman","y":2016,"p":"https://images.metahub.space/poster/small/tt5700648/img","b":"https://images.metahub.space/background/medium/tt5700648/img"},{"i":"tt4844288","t":"The Treacherous","y":2015,"p":"https://images.metahub.space/poster/small/tt4844288/img","b":"https://images.metahub.space/background/medium/tt4844288/img"},{"i":"tt1330206","t":"Portrait of a Beauty","y":2008,"p":"https://images.metahub.space/poster/small/tt1330206/img","b":"https://images.metahub.space/background/medium/tt1330206/img"},{"i":"tt0380689","t":"Untold Scandal","y":2003,"p":"https://images.metahub.space/poster/small/tt0380689/img","b":"https://images.metahub.space/background/medium/tt0380689/img"},{"i":"tt0297414","t":"Summertime","y":2001,"p":"https://images.metahub.space/poster/small/tt0297414/img","b":"https://images.metahub.space/background/medium/tt0297414/img"}]};

var REGION_ANCHORS = {
    us: "tt0477457",
    eu: "tt0071464",
    jp: "tt0074102",
    hk: "tt0105287",
    kr: "tt4016934"
};

var ANCHOR_REGIONS = {
    tt0477457: "us",
    tt0071464: "eu",
    tt0074102: "jp",
    tt0105287: "hk",
    tt4016934: "kr"
};

var REGION_TITLES = {
    us: "Mỹ · Cổ Điển",
    eu: "Châu Âu · Cổ Điển",
    jp: "Nhật · Cổ Điển",
    hk: "Hong Kong · Trung Quốc",
    kr: "Hàn Quốc"
};

function getHomeSections() {
    return JSON.stringify([
        { slug: 'ad:tpdb_cat', title: 'Mới Nhất · ThePornDB', type: 'Horizontal', path: '' },
        { slug: 'ad:xxx_recent', title: '4K · Mới Nhất', type: 'Horizontal', path: '' },
        { slug: 'ad:xxx_top', title: '4K · Hay Nhất', type: 'Horizontal', path: '' },
        { slug: 'ad:xxx_fhd_recent', title: '1080p · Mới Nhất', type: 'Horizontal', path: '' },
        { slug: 'ad:curated_recent', title: 'Tuyển Chọn · 4K', type: 'Horizontal', path: '' },
        { slug: 'ad:xxx_studio_1pondo_fhd_recent', title: 'JAV · 1Pondo', type: 'Horizontal', path: '' },
        { slug: 'ad:xxx_studio_10musume_fhd_recent', title: 'JAV · 10musume', type: 'Horizontal', path: '' },
        { slug: 'lane:us', title: REGION_TITLES.us, type: 'Horizontal', path: '' },
        { slug: 'lane:eu', title: REGION_TITLES.eu, type: 'Horizontal', path: '' },
        { slug: 'lane:jp', title: REGION_TITLES.jp, type: 'Horizontal', path: '' },
        { slug: 'lane:hk', title: REGION_TITLES.hk, type: 'Horizontal', path: '' },
        { slug: 'lane:kr', title: REGION_TITLES.kr, type: 'Horizontal', path: '' }
    ]);
}

function getPrimaryCategories() {
    var sections = JSON.parse(getHomeSections());
    var cats = [];
    for (var i = 0; i < sections.length; i++) {
        cats.push({ name: sections[i].title, slug: sections[i].slug });
    }
    return JSON.stringify(cats);
}

function getFilterConfig() {
    return JSON.stringify({});
}

// =============================================================================
// URL GENERATION — parseListResponse receives no slug, so getUrlList
// stashes the slug + page in session vars (the engine serialises its
// calls, and list loads for one plugin are issued one at a time).
// =============================================================================

var LAST_SLUG = "";
var LAST_PAGE = 1;

function getUrlList(slug, filtersJson) {
    var filters = {};
    try { filters = JSON.parse(filtersJson || "{}"); } catch (e) {}
    var page = filters.page || 1;
    LAST_SLUG = slug || "";
    LAST_PAGE = page;
    if (LAST_SLUG.indexOf('lane:') === 0) {
        // Curated rails are embedded below; the contract still wants
        // a URL to fetch. Fetch the region's ANCHOR meta — the
        // payload itself then tells parseListResponse which region
        // it belongs to, so parallel rail loads (the Home tab loads
        // sections concurrently) can never cross-wire two rails.
        var anchor = REGION_ANCHORS[LAST_SLUG.slice(5)] || REGION_ANCHORS.us;
        return CINEMETA + "/meta/movie/" + anchor + ".json";
    }
    if (LAST_SLUG.indexOf('ad:') === 0) {
        var cat = LAST_SLUG.slice(3);
        var url = ADDON_BASE + "/catalog/" + ADDON_TYPE + "/" + cat;
        if (page > 1) url += "/skip=" + ((page - 1) * 20);
        return url + ".json";
    }
    return ADDON_BASE + "/catalog/" + ADDON_TYPE + "/xxx_recent.json";
}

function getUrlSearch(keyword, filtersJson) {
    return ADDON_BASE + "/catalog/" + ADDON_TYPE + "/search/search=" + encodeURIComponent(keyword || "") + ".json";
}

// Pure-JS base64 decode (JavaScriptCore has no atob): standard and
// URL-safe alphabets, padding optional. Returns the decoded UTF-8
// string or "" on any malformed input.
function thB64Decode(str) {
    var alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var s = String(str || "").replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
    var out = "";
    var buf = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
        var v = alpha.indexOf(s.charAt(i));
        if (v < 0) return "";
        buf = (buf << 6) | v; bits += 6;
        if (bits >= 8) { bits -= 8; out += String.fromCharCode((buf >> bits) & 255); }
    }
    try { return decodeURIComponent(escape(out)); } catch (e) { return out; }
}

function thB64DecodeJson(str) {
    try { var t = thB64Decode(str); return t ? JSON.parse(t) : null; } catch (e) { return null; }
}

/// Search query for a scene release title: drop bracket tags, date
/// tokens and format tokens, keep the first 3 content tokens (studio
/// + distinctive words). A full release name ANDs to zero hits on the
/// index; the short form was verified to return the scene's variants.
function thApibayQuery(title) {
    var t = String(title || "").replace(/\[[^\]]*\]/g, " ");
    var raw = t.split(/[^A-Za-z0-9]+/);
    var stop = /^(2160p|1440p|1080p|720p|576p|480p|360p|4k|uhd|fhd|xxx|mp4|mkv|avi|web|webrip|webdl|wrb|hdrip|bdrip|bluray|x264|x265|h264|h265|hevc|aac|mp3)$/i;
    var keep = [];
    for (var i = 0; i < raw.length && keep.length < 3; i++) {
        var w = raw[i];
        if (!w || /^\d+$/.test(w) || stop.test(w)) continue;
        keep.push(w);
    }
    return keep.join(" ");
}

function getUrlDetail(slug) {
    if (!slug) return "";
    if (slug.indexOf('jtvstreams:') === 0) {
        var rest = slug.slice('jtvstreams:'.length);
        if (rest.indexOf('ad:') === 0) {
            var addonId = rest.slice(3);
            // Lane B items carry ONE torrent in the addon payload, so
            // stage 2 searches a public torrent index by the release
            // title for real alternatives (v1.0.3). The original hash
            // rides along as jtvfb so a no-hit search still yields the
            // addon's own torrent as the single episode.
            if (addonId.indexOf('jstrm:') === 0) {
                var payload = thB64DecodeJson(addonId.slice(6));
                if (payload && payload.h && payload.t) {
                    var q = thApibayQuery(payload.t);
                    if (q) return "https://apibay.org/q.php?q=" + encodeURIComponent(q) + "&jtvfb=" + payload.h;
                }
            }
            return ADDON_BASE + "/stream/" + ADDON_TYPE + "/" + encodeURIComponent(addonId) + ".json";
        }
        return TORRENTIO + "/stream/movie/" + rest + ".json";
    }
    if (slug.indexOf('ad:') === 0) {
        return ADDON_BASE + "/meta/" + ADDON_TYPE + "/" + encodeURIComponent(slug.slice(3)) + ".json";
    }
    if (slug.indexOf('tt') === 0) {
        return CINEMETA + "/meta/movie/" + slug + ".json";
    }
    if (slug.indexOf('http') === 0) return slug;
    return "";
}

function getUrlCategories() { return ""; }
function getUrlCountries() { return ""; }
function getUrlYears() { return ""; }

// =============================================================================
// LIST PARSING
// =============================================================================

function thAddonItems(j) {
    var metas = (j && j.metas) || [];
    var items = [];
    for (var i = 0; i < metas.length; i++) {
        var m = metas[i];
        if (!m.id || !m.name) continue;
        // 1.0.4: the addon's upstream feeds carry junk entries whose
        // whole title is a number + a format token ("001 mp4") — they
        // crowded the 4K rails (3-5 per page). Drop exactly those.
        // 1.0.5: a second junk shape seen on device — "self 23962 mkv".
        if (/^\s*\d{1,4}\s*(mp4|mkv|avi|wmv|xxx)?\s*$/i.test(m.name)) continue;
        if (/^\s*self\s+(\d{4,}|\d+\s+(mp4|mkv|avi|wmv|mov|xxx))\s*$/i.test(m.name)) continue;
        var year = 0;
        var ym = String(m.releaseInfo || "").match(/(18|19|20)\d{2}/);
        if (ym) year = parseInt(ym[0]);
        items.push({
            id: "ad:" + m.id,
            title: m.name,
            posterUrl: m.poster || "",
            backdropUrl: m.background || m.poster || "",
            year: year
        });
    }
    return items;
}

function parseListResponse(text) {
    var probe;
    try { probe = JSON.parse(text); } catch (e) { probe = null; }
    var anchorId = probe && probe.meta ? (probe.meta.imdb_id || probe.meta.id || "") : "";
    var anchorRegion = ANCHOR_REGIONS[anchorId] || "";
    if (anchorRegion) {
        var region = anchorRegion;
        var list = CURATED[region] || [];
        var items = [];
        for (var i = 0; i < list.length; i++) {
            items.push({
                id: list[i].i,
                title: list[i].t,
                posterUrl: list[i].p,
                backdropUrl: list[i].b || list[i].p,
                year: list[i].y || 0
            });
        }
        return JSON.stringify({ items: items, pagination: { currentPage: 1, totalPages: 1 } });
    }
    var j;
    try { j = JSON.parse(text); } catch (e) { return JSON.stringify({ items: [], pagination: { currentPage: 1, totalPages: 1 } }); }
    var items = thAddonItems(j);
    // 1.0.7: the has-next-page signal must come from the RAW page size.
    // thAddonItems drops junk titles, so deciding on the filtered count
    // collapsed totalPages to the current page whenever a full raw page
    // lost even one title to the filter (xxx_top p1 keeps 17 of 20) and
    // the app stopped loading further pages entirely.
    var rawCount = (j && j.metas) ? j.metas.length : 0;
    var totalPages = rawCount >= 20 ? LAST_PAGE + 1 : LAST_PAGE;
    return JSON.stringify({ items: items, pagination: { currentPage: LAST_PAGE, totalPages: totalPages } });
}

function parseSearchResponse(text) {
    var j;
    try { j = JSON.parse(text); } catch (e) { return JSON.stringify({ items: [], pagination: { currentPage: 1, totalPages: 1 } }); }
    return JSON.stringify({ items: thAddonItems(j), pagination: { currentPage: 1, totalPages: 1 } });
}

// =============================================================================
// DETAIL — stage 1 (meta payload) returns the full record + one
// "jtvstreams:" placeholder episode; stage 2 (streams payload)
// returns a stub whose servers the app swaps in.
// =============================================================================

function thDetailStub(servers) {
    return JSON.stringify({
        id: "",
        title: "",
        posterUrl: "",
        backdropUrl: "",
        description: "",
        servers: servers,
        category: "",
        status: "Full",
        year: 0
    });
}

function thQualityRank(q) {
    if (q === '2160p' || q === '4K' || q === 'UHD') return 4;
    if (q === '1440p') return 3.5;
    if (q === '1080p') return 3;
    if (q === '720p') return 2;
    if (q === '576p') return 1.5;
    if (q === '480p') return 1;
    if (q === '360p') return 0.5;
    return 0;
}

/// 1.0.5: quality detection beyond the four classic tokens. Real
/// payloads carry 1440p releases (measured on apibay: a 1440p copy
/// ranked 0 and sank below 480p despite its seeds), FHD tags,
/// "1920x1080"-style dimensions and bare resolution numbers. Only
/// unambiguous signals are read; a name with no resolution signal
/// at all (e.g. a bare "BDRip") stays unknown — no rank is invented.
function thDetectQuality(text) {
    var m = text.match(/(2160p|1440p|1080p|720p|576p|480p|360p|4K|UHD)/i);
    if (m) {
        var u = m[1].toUpperCase();
        if (u === '4K') return '4K';
        if (u === 'UHD') return 'UHD';
        return m[1].toLowerCase();
    }
    if (/\bFHD\b/i.test(text)) return '1080p';
    if (/3840\s*[x×]\s*2160/.test(text)) return '2160p';
    if (/2560\s*[x×]\s*1440/.test(text)) return '1440p';
    if (/1920\s*[x×]\s*1080/.test(text)) return '1080p';
    if (/1280\s*[x×]\s*720/.test(text)) return '720p';
    var b = text.match(/\b(2160|1440|1080|720)\b/);
    if (b) return b[1] + 'p';
    return '';
}

function thStreamLabel(release, metaLine, nameField) {
    var text = (release || "") + " " + (nameField || "");
    var quality = thDetectQuality(text);
    var cm = text.match(/\.(mkv|mp4|avi|m4v|ts|wmv)\b/i);
    var container = cm ? cm[1].toUpperCase() : "";
    var seeds = 0, size = "", sizeMB = 0;
    if (metaLine) {
        var sm = metaLine.match(/👤\s*(\d+)/);
        if (sm) seeds = parseInt(sm[1]);
        var zm = metaLine.match(/💾\s*([0-9.]+\s*[KMGT]B)/i);
        if (zm) {
            size = zm[1].replace(/\s+/g, " ");
            var sp = size.match(/([0-9.]+)\s*([KMGT]B)/i);
            if (sp) {
                var mult = { KB: 1 / 1024, MB: 1, GB: 1024, TB: 1024 * 1024 }[sp[2].toUpperCase()] || 0;
                sizeMB = parseFloat(sp[1]) * mult;
            }
        }
    }
    var parts = [];
    if (quality) parts.push(quality);
    if (container) parts.push(container);
    if (size) parts.push(size);
    if (seeds > 0) parts.push("👤 " + seeds);
    return { label: parts.join(" · "), seeds: seeds, rank: thQualityRank(quality), sizeMB: sizeMB };
}

function thSortedStreams(streams) {
    var eps = [];
    for (var i = 0; i < streams.length; i++) {
        var s = streams[i];
        var title = s.title || "";
        var lines = title.split("\n");
        var release = lines[0] || "";
        var metaLine = lines.length > 1 ? lines[1] : "";
        if (s.infoHash) {
            var info = thStreamLabel(release, metaLine, s.name || "");
            var label = info.label;
            if (!label) label = (s.name || "Torrent").replace(/^🧲\s*/, "");
            eps.push({
                id: "jtvhash:" + String(s.infoHash).toLowerCase(),
                name: label,
                slug: "s" + i,
                _seeds: info.seeds,
                _rank: info.rank,
                _sizeMB: info.sizeMB
            });
        } else if (s.url) {
            eps.push({
                id: s.url,
                name: (s.name || "Trực tiếp") + (s.title ? " · " + String(s.title).split("\n")[0] : ""),
                slug: "s" + i,
                _seeds: 0,
                _rank: 0,
                _sizeMB: 0
            });
        }
    }
    // Owner's selection criterion (2026-11-16): QUALITY first —
    // FHD (1080p) is the floor of the top group, higher quality
    // above it; within one quality tier the fastest source wins
    // (most seeds), then the larger file. Weaker/unknown quality
    // only after every FHD-or-better source. (Before this the sort
    // was seeds-first, which put high-seed 720p/unknown files above
    // 2160p/1080p ones.)
    eps.sort(function (a, b) {
        if (b._rank !== a._rank) return b._rank - a._rank;
        if (b._seeds !== a._seeds) return b._seeds - a._seeds;
        return b._sizeMB - a._sizeMB;
    });
    if (eps.length > 40) eps = eps.slice(0, 40);
    return eps;
}

function thStripMeta(eps) {
    var out = [];
    for (var j = 0; j < eps.length; j++) {
        out.push({ id: eps[j].id, name: eps[j].name, slug: eps[j].slug });
    }
    return out;
}

function thEpisodesFromStreams(streams, isTorrentio) {
    return thStripMeta(thSortedStreams(streams));
}

/// The owner's "good sources" shortlist (2026-11-16): FHD-or-better
/// entries only, in the standard quality order, at most 5. Empty
/// when the title has no FHD+ source at all — nothing is labelled
/// "recommended" that does not meet the FHD floor.
function thRecommendedFromStreams(streams) {
    var sorted = thSortedStreams(streams);
    var good = [];
    for (var i = 0; i < sorted.length && good.length < 5; i++) {
        if (sorted[i]._rank >= 3) good.push(sorted[i]);
    }
    return thStripMeta(good);
}

function parseMovieDetail(text, pageUrl) {
    var j;
    try { j = JSON.parse(text); } catch (e) { return "null"; }
    if ((pageUrl || "").indexOf('apibay.org') >= 0 && j && j.length !== undefined) {
        // Lane B stage 2 (v1.0.3): rows from a public torrent index
        // search, mapped into the same stream shape Torrentio uses so
        // the standard sort/label/⭐ logic applies unchanged.
        var streams = [];
        for (var ai = 0; ai < j.length; ai++) {
            var row = j[ai];
            if (!row || !row.info_hash || !row.name || row.name === "No results returned") continue;
            var bytes = parseInt(row.size || 0);
            var sizeStr = bytes >= 1073741824 ? (bytes / 1073741824).toFixed(2) + " GB"
                        : bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + " MB" : "";
            streams.push({
                infoHash: String(row.info_hash).toLowerCase(),
                name: "🧲 Torrent",
                title: row.name + "\n👤 " + (row.seeders || 0) + (sizeStr ? " 💾 " + sizeStr : "")
            });
        }
        if (streams.length) {
            var aeps = thEpisodesFromStreams(streams, false);
            var aservers = [{ name: "Torrent", episodes: aeps }];
            var agood = thRecommendedFromStreams(streams);
            if (agood.length) aservers.push({ name: "⭐ Nguồn đề xuất", episodes: agood });
            return thDetailStub(aservers);
        }
        var fbm = (pageUrl || "").match(/jtvfb=([0-9a-fA-F]{32,40})/);
        if (fbm) {
            return thDetailStub([{ name: "Torrent", episodes: [{ id: "jtvhash:" + fbm[1].toLowerCase(), name: "Nguồn gốc", slug: "s0" }] }]);
        }
        return "null";
    }
    if (j && j.streams) {
        var isTio = (pageUrl || "").indexOf('torrentio') >= 0;
        var eps = thEpisodesFromStreams(j.streams, isTio);
        var servers = [{ name: isTio ? "Torrentio" : "Torrent", episodes: eps }];
        // Owner request (2026-11-16): a recommended-good-sources
        // section UNDER the full list, for manual picking when the
        // first choice stalls. Only FHD+ entries qualify.
        var good = thRecommendedFromStreams(j.streams);
        if (good.length) servers.push({ name: "⭐ Nguồn đề xuất", episodes: good });
        return thDetailStub(servers);
    }
    var m = (j && j.meta) || null;
    if (!m) return "null";
    var isAddon = (pageUrl || "").indexOf('debrid.in') >= 0;
    var itemId = isAddon ? ("ad:" + m.id) : (m.imdb_id || m.id || "");
    var year = 0;
    var ym = String(m.year || m.releaseInfo || "").match(/(18|19|20)\d{2}/);
    if (ym) year = parseInt(ym[0]);
    var casts = [];
    if (m.cast && m.cast.length) casts = m.cast.slice(0, 8);
    var detail = {
        id: itemId,
        title: m.name || "",
        originName: "",
        posterUrl: m.poster || "",
        backdropUrl: m.background || m.poster || "",
        description: m.description || "",
        servers: [{ name: "Torrent", episodes: [{ id: "jtvstreams:" + itemId, name: "Đang tải danh sách nguồn…", slug: "streams" }] }],
        category: (m.genres || []).join(", "),
        status: "Full",
        year: year
    };
    if (casts.length) detail.castNames = casts;
    if (m.imdbRating) {
        var r = parseFloat(m.imdbRating);
        if (!isNaN(r)) detail.rating = r;
    }
    return JSON.stringify(detail);
}

// Playback parsers: the app intercepts "jtvhash:" episode ids before
// the embed chain, and direct-url episodes never reach here either.
// Return an empty stream so any stray call resolves to "no source"
// instead of crashing.
function parseDetailResponse(text, fetchedUrl) {
    return JSON.stringify({ url: "", isEmbed: false, headers: {} });
}

function parseEmbedResponse(html, url) {
    return JSON.stringify({ url: "", isEmbed: false, headers: {} });
}
