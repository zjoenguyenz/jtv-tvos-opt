// =============================================================================
// SayHentai plugin v3.0.0 — rewritten 2026-11-18 for sayhentai.cx's new
// platform. History: the operator's old Madara site lived at .cx, was
// abandoned for sayhentai.sale (v2.x of this plugin), but .sale serves
// cut-down pages (~720px slices, promo banners bookending chapters).
// The .cx domain is back on a different platform (Laravel-style) and
// serves the full-quality version: chapter pages are intact long
// strips (measured 720x~10,000) with no injected promos — the owner
// confirmed .cx is the HD copy and ordered the move back.
// Verified 2026-11-18 from the owner's own device browser:
//   list    /  and /genre/<slug> and /completed, cards are anchors to
//           /truyen-<slug>.html wrapping a cover <img> at
//           /storage/images/cover/<file> (filenames may contain spaces
//           and Vietnamese — percent-encoded below)
//   paging  ?page=N (homepage shows 300 pages)
//   detail  /truyen-<slug>.html, chapters at /truyen-<slug>/chuong-<n>
//   reader  <img> tags (no wrapper class) on cdn.pubtranxzyzz.store,
//           signed URLs (?token=...&expires=..., ~8 h life — the app
//           fetches the chapter page fresh at open, so tokens are new)
//   search  /search?s=<keyword>
//   genres  /genre index; the comic page's own genre field can be
//           empty, so detail returns no categories (the header nav
//           would mislabel every comic with the same genres).
// .cx sits behind a Cloudflare check for datacenter IPs; the owner's
// device loads it directly, and the app's WebView fallback covers a
// challenged fetch.
//
// v3.2.0 (2026-11-20) — mirror gap-fill (Shape A, owner-approved).
// .cx prunes the middle out of some titles' chapter runs (proven on
// device: one title listing only 1, 7, 10, 19, 26, 49, … of 1–66).
// khotruyen.win — a front-end of the same house's older Madara
// catalogue — carries the same slugs essentially gap-free (measured:
// 43 of 8,890 titles have any gap; the pruned title is complete
// 1–81 there). When a detail's chapter list has interior gaps, the
// detail goes two-stage (the app's torrenthub mechanism): stage 1
// returns a "jtvstreams:mirror:<slug>" placeholder, the app fetches
// the mirror's title page, and stage 2 merges in ONLY the missing
// chapter numbers, pointing at the mirror's reader pages (tagged
// "source":"mirror"; their URLs ride image.shtcdn.top). Source
// chapters keep their exact entries; a gap-free title never touches
// the mirror; a mirror page that fails, 404s or parses to nothing
// returns the source list unchanged (an app-level fetch failure
// instead keeps the stage-1 placeholder — the standard two-stage
// failure mode, identical to torrenthub's). The mirror is smaller
// and slower than .cx, so it fills gaps ONLY — never the tail past
// .cx's latest chapter.
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "sayhentai",
        "name": "SayHentai",
        "version": "3.2.0",
        "baseUrl": "https://sayhentai.cx",
        "iconUrl": "https://sayhentai.cx/favicon.ico",
        "isEnabled": true,
        "isAdult": true,
        "type": "MANGA",
        "layoutType": "VERTICAL"
    });
}

function getHomeSections() {
    // v3.1.0: a real catalogue like the movie plugins carry — genre
    // rails (Horizontal) over the main grid. Every path below is a
    // list shape verified on .cx (homepage / genre / completed all
    // serve the same card anchors parseListResponse reads), and
    // getUrlList already routes all three forms.
    return JSON.stringify([
        { slug: 'genre/manhwa', title: 'Manhwa', type: 'Horizontal', path: '' },
        { slug: 'genre/khong-che', title: 'Không Che', type: 'Horizontal', path: '' },
        { slug: 'completed', title: 'Truyện Full', type: 'Horizontal', path: '' },
        { slug: 'genre/doujinshi', title: 'Doujinshi', type: 'Horizontal', path: '' },
        { slug: 'genre/oneshot', title: 'Oneshot', type: 'Horizontal', path: '' },
        { slug: '', title: 'Truyện Mới Cập Nhật', type: 'Grid', path: '' }
    ]);
}

function getPrimaryCategories() {
    // Every slug verified live on sayhentai.cx/genre, 2026-11-18.
    return JSON.stringify([
        { name: 'Mới Nhất', slug: '' },
        { name: 'Truyện Full', slug: 'completed' },
        { name: 'Manhwa', slug: 'genre/manhwa' },
        { name: 'Manga', slug: 'genre/manga' },
        { name: 'Doujinshi', slug: 'genre/doujinshi' },
        { name: 'Oneshot', slug: 'genre/oneshot' },
        { name: 'Adult', slug: 'genre/adult' },
        { name: 'Ecchi', slug: 'genre/ecchi' },
        { name: 'Harem', slug: 'genre/harem' },
        { name: 'Milf', slug: 'genre/milf' },
        { name: 'Drama', slug: 'genre/drama' },
        { name: 'Romance', slug: 'genre/romance' },
        { name: 'NTR', slug: 'genre/ntr' },
        { name: 'Không Che', slug: 'genre/khong-che' },
        { name: 'Ngực Lớn', slug: 'genre/nguc-lon' },
        { name: 'Nữ Sinh', slug: 'genre/nu-sinh' },
        { name: 'Housewife', slug: 'genre/housewife' }
    ]);
}

function getFilterConfig() {
    return JSON.stringify({
        sort: [
            { name: 'Mới cập nhật', value: 'latest' }
        ],
        category: [
            { name: "Manhwa", value: "manhwa" },
            { name: "Manga", value: "manga" },
            { name: "Doujinshi", value: "doujinshi" },
            { name: "Oneshot", value: "oneshot" },
            { name: "Adult", value: "adult" },
            { name: "Ecchi", value: "ecchi" },
            { name: "Harem", value: "harem" },
            { name: "Milf", value: "milf" },
            { name: "Drama", value: "drama" },
            { name: "Romance", value: "romance" },
            { name: "NTR", value: "ntr" },
            { name: "Không Che", value: "khong-che" },
            { name: "Ngực Lớn", value: "nguc-lon" },
            { name: "Nữ Sinh", value: "nu-sinh" },
            { name: "Housewife", value: "housewife" },
            { name: "Group", value: "group" },
            { name: "Series", value: "series" },
            { name: "Smut", value: "smut" },
            { name: "Mind Break", value: "mind-break" },
            { name: "18+", value: "18" }
        ]
    });
}

// =============================================================================
// URL GENERATION
// =============================================================================

var BASE = "https://sayhentai.cx";
var MIRROR = "https://khotruyen.win";

// v3.2.0: stage-1 → stage-2 hand-off for the mirror gap-fill. The
// app keeps one JS context per plugin and serializes its calls
// (the same property hentaihub's chain stash relies on). The stash
// is keyed by slug (two detail loads may interleave at the app's
// fetch awaits), each entry is single-use — a stage-2 call takes
// and drops its own title's entry — and the key set is FIFO-
// capped so abandoned entries cannot accumulate.
// (The map is prototype-less: "constructor" is a legal slug, and
// on a plain {} it would read Object.prototype members instead of
// a missing entry.)
var _shFill = Object.create(null);
var _shFillOrder = [];

function shStashFill(slug, chapters) {
    var i = _shFillOrder.indexOf(slug);
    if (i !== -1) _shFillOrder.splice(i, 1);
    _shFillOrder.push(slug);
    _shFill[slug] = chapters;
    while (_shFillOrder.length > 8) {
        delete _shFill[_shFillOrder.shift()];
    }
}

function shTakeFill(slug) {
    var chapters = _shFill[slug] || null;
    if (chapters) {
        delete _shFill[slug];
        var i = _shFillOrder.indexOf(slug);
        if (i !== -1) _shFillOrder.splice(i, 1);
    }
    return chapters;
}

// Host-anchored mirror test (a bare substring match would also
// fire on look-alike hosts and on the string appearing in a query
// parameter of a .cx URL).
function shIsMirrorUrl(url) {
    return typeof url === "string" && url.indexOf(MIRROR + "/") === 0;
}

function getUrlList(slug, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;

    if (filters.category) {
        return BASE + "/genre/" + filters.category + "?page=" + page;
    }
    if (slug && slug.indexOf('genre/') === 0) {
        return BASE + "/" + slug + "?page=" + page;
    }
    if (slug === 'completed') {
        return BASE + "/completed?page=" + page;
    }
    return BASE + "/?page=" + page;
}

function getUrlSearch(keyword, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    var url = BASE + "/search?s=" + encodeURIComponent(keyword);
    if (page > 1) url += "&page=" + page;
    return url;
}

function getUrlDetail(slug) {
    if (!slug) return "";
    // v3.2.0 stage 2: the app feeds the placeholder episode's id
    // back through here to obtain the mirror's title page.
    if (slug.indexOf("jtvstreams:mirror:") === 0) {
        return MIRROR + "/truyen/" + slug.slice("jtvstreams:mirror:".length) + "/";
    }
    if (slug.indexOf("http") === 0) return slug;
    return BASE + "/truyen-" + slug + ".html";
}

function getUrlCategories() { return BASE + "/genre"; }
function getUrlCountries() { return ""; }
function getUrlYears() { return ""; }

// =============================================================================
// UTILS
// =============================================================================

var PluginUtils = {
    cleanText: function (text) {
        if (!text) return "";
        return text.replace(/<[^>]*>/g, "")
            .replace(/&amp;/g, "&")
            .replace(/&quot;/g, '"')
            .replace(/&#039;/g, "'")
            .replace(/&#39;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/\s+/g, " ")
            .trim();
    },
    // Cover filenames on .cx can contain spaces and Vietnamese
    // characters; a raw URL(string:) would reject those, so encode.
    encodeUrl: function (url) {
        if (!url) return "";
        try { return encodeURI(url.replace(/&amp;/g, "&")); } catch (e) { return url; }
    }
};

// =============================================================================
// PARSERS
// =============================================================================

function parseListResponse(html) {
    var items = [];
    var foundSlugs = {};

    // Cards: an anchor to /truyen-<slug>.html whose block carries the
    // cover <img> (src, alt = title). The homepage repeats a comic
    // across sections, so dedupe by slug.
    var cardRegex = /<a[^>]+href="https:\/\/sayhentai\.cx\/truyen-([a-z0-9-]+)\.html"[^>]*>([\s\S]*?)<\/a>/gi;
    var card;
    while ((card = cardRegex.exec(html)) !== null) {
        var slug = card[1];
        if (foundSlugs[slug]) continue;
        var block = card[2];

        var imgMatch = block.match(/<img[^>]+src="([^"]+)"/i) ||
            block.match(/<img[^>]+data-src="([^"]+)"/i);
        var thumb = imgMatch ? PluginUtils.encodeUrl(imgMatch[1]) : "";

        var title = "";
        var altMatch = block.match(/<img[^>]+alt="([^"]*)"/i);
        if (altMatch) title = PluginUtils.cleanText(altMatch[1]);
        if (!title) title = PluginUtils.cleanText(block);
        if (!title) title = slug;

        var epMatch = block.match(/Chapter\s+([\d.]+)/i);
        var episode = epMatch ? ("Chapter " + epMatch[1]) : "";

        foundSlugs[slug] = true;
        items.push({
            id: slug,
            title: title,
            posterUrl: thumb,
            backdropUrl: thumb,
            description: "",
            episode_current: episode,
            quality: "HD",
            lang: "Vietsub"
        });
    }

    // Pagination: total from the ?page= links (verified shape).
    var currentPage = 1;
    var curMatch = html.match(/class="[^"]*active[^"]*"[^>]*>\s*(?:<a[^>]*>)?\s*(\d+)/i);
    if (curMatch) currentPage = parseInt(curMatch[1]);

    var totalPages = currentPage;
    var pageRegex = /[?&]page=(\d+)/g;
    var pMatch;
    while ((pMatch = pageRegex.exec(html)) !== null) {
        var p = parseInt(pMatch[1]);
        if (p > totalPages) totalPages = p;
    }

    return JSON.stringify({
        items: items,
        pagination: {
            currentPage: currentPage,
            totalPages: totalPages || 1,
            totalItems: items.length * (totalPages || 1),
            itemsPerPage: items.length
        }
    });
}

function parseSearchResponse(html) {
    return parseListResponse(html);
}

function parseMovieDetail(html, url) {
    // v3.2.0 stage 2 lands here with the mirror's title page.
    if (shIsMirrorUrl(url)) return shMirrorMerge(html, url);
    try {
        // Title
        var title = "";
        var ogTitle = html.match(/<meta property="og:title" content="([^"]+)"/i);
        if (ogTitle) title = PluginUtils.cleanText(ogTitle[1]).replace(/\s*[|-]\s*SayHentai\s*$/i, "");
        if (!title) {
            var h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
            if (h1) title = PluginUtils.cleanText(h1[1]);
        }
        if (!title) {
            var coverAlt = html.match(/<img[^>]+src="[^"]*\/storage\/images\/cover\/[^"]*"[^>]+alt="([^"]*)"/i);
            if (coverAlt) title = PluginUtils.cleanText(coverAlt[1]);
        }

        // Poster: og:image, else the page's own cover image.
        var poster = "";
        var ogImage = html.match(/<meta property="og:image" content="([^"]+)"/i);
        if (ogImage) poster = ogImage[1];
        if (!poster) {
            var cover = html.match(/<img[^>]+src="(https:\/\/sayhentai\.cx\/storage\/images\/cover\/[^"]+)"/i);
            if (cover) poster = cover[1];
        }
        poster = PluginUtils.encodeUrl(poster);

        // Description: og:description is the only verified-safe source
        // (the detail body markup was not exposed by the survey).
        var description = "";
        var ogDesc = html.match(/<meta property="og:description" content="([^"]*)"/i);
        if (ogDesc) description = PluginUtils.cleanText(ogDesc[1]).substring(0, 700);

        // Chapters: anchors to /truyen-<slug>/chuong-<n> (verified).
        var chapters = [];
        var seenChap = {};
        var chapRegex = /<a[^>]+href="(https:\/\/sayhentai\.cx\/truyen-[a-z0-9-]+\/chuong-([\d.]+))"[^>]*>/gi;
        var cMatch;
        while ((cMatch = chapRegex.exec(html)) !== null) {
            if (!seenChap[cMatch[1]]) {
                seenChap[cMatch[1]] = true;
                chapters.push({
                    id: cMatch[1],
                    name: "Chapter " + cMatch[2],
                    slug: "chuong-" + cMatch[2],
                    num: parseFloat(cMatch[2])
                });
            }
        }
        chapters.sort(function (a, b) { return a.num - b.num; });

        // v3.2.0: interior-gap plan. Only whole-number chapters
        // define the run; a missing integer strictly between the
        // first and last whole numbers is a pruned chapter. The
        // tail past the last chapter is NOT a gap (fresh chapters
        // are .cx's job — the mirror trails it on most titles).
        var fillSlug = shGapSlug(url, chapters);

        for (var j = 0; j < chapters.length; j++) delete chapters[j].num;

        var servers;
        if (fillSlug) {
            // Two-stage detail (the app's torrenthub mechanism):
            // stage 1 renders this record with a placeholder
            // episode; the app fetches the mirror title page via
            // getUrlDetail and stage 2 swaps in the merged list.
            shStashFill(fillSlug, chapters);
            servers = [{
                name: "Server 1",
                episodes: [{
                    id: "jtvstreams:mirror:" + fillSlug,
                    name: "Đang tải danh sách nguồn…",
                    slug: "mirrorfill"
                }]
            }];
        } else {
            servers = [{
                name: "Server 1",
                episodes: chapters
            }];
        }

        return JSON.stringify({
            id: "",
            title: title,
            posterUrl: poster,
            backdropUrl: poster,
            description: description,
            servers: servers,
            category: "",
            status: "Đang tiến hành",
            quality: "HD",
            lang: "Vietsub"
        });

    } catch (e) {
        return "null";
    }
}

// =============================================================================
// v3.2.0 — MIRROR GAP-FILL (Shape A)
// =============================================================================

// The detail page's slug, when the chapter list (entries still
// carrying their numeric `num`) has at least one interior integer
// gap; "" when the run is whole or the slug cannot be determined.
// Adjacency over the distinct whole numbers actually present —
// never a scan of the numeric range (unbounded, and above 2^53 a
// float counter stops advancing altogether).
function shGapSlug(url, chapters) {
    var m = (typeof url === "string" ? url : "").match(/truyen-([a-z0-9-]+)\.html/i);
    if (!m || chapters.length < 2) return "";
    var seen = {}, nums = [];
    for (var i = 0; i < chapters.length; i++) {
        var n = chapters[i].num;
        if (typeof n !== "number" || !Number.isSafeInteger(n)) continue;
        if (!seen[n]) { seen[n] = true; nums.push(n); }
    }
    if (nums.length < 2) return "";
    nums.sort(function (a, b) { return a - b; });
    for (var k = 1; k < nums.length; k++) {
        if (nums[k] > nums[k - 1] + 1) return m[1];
    }
    return "";
}

// Fill candidates on a mirror title page (verified live shape:
// relative hrefs /truyen/<slug>/chuong/<n>/, whole run on one
// page). Only CANONICAL integer tokens qualify — "02", "2.0" or
// "10." would parseFloat-collapse onto a real chapter's number,
// claim its slot and point at a non-canonical (dead) path, so
// they are rejected here and can never shadow the genuine anchor.
// Returns [{num, numStr, url}] deduped by path.
function shParseMirrorChapters(html, slug) {
    var out = [];
    var seen = {};
    var re = new RegExp('<a[^>]+href="(?:https://khotruyen\\.win)?(/truyen/' +
        slug + '/chuong/([\\d.]+)/?)"[^>]*>', 'gi');
    var mm;
    while ((mm = re.exec(html)) !== null) {
        var token = mm[2];
        if (!/^\d+$/.test(token) || String(parseInt(token, 10)) !== token) continue;
        var path = mm[1];
        if (path.charAt(path.length - 1) !== "/") path += "/";
        if (seen[path]) continue;
        seen[path] = true;
        out.push({ num: parseInt(token, 10), numStr: token, url: MIRROR + path });
    }
    return out;
}

// Stage 2 returns a stub record: the app reads only its servers.
function shMirrorStub(servers) {
    return JSON.stringify({
        id: "",
        title: "",
        posterUrl: "",
        backdropUrl: "",
        description: "",
        servers: servers,
        category: "",
        status: "Đang tiến hành",
        quality: "HD",
        lang: "Vietsub"
    });
}

// Stage 2: merge the mirror's chapters into the stashed source
// list. Failure discipline: whatever goes wrong, the answer is
// the source list itself (today's behaviour); only a missing
// stash entry (never stashed, already consumed, or evicted)
// yields an empty server list, which makes the app keep the
// stage-1 record untouched.
function shMirrorMerge(html, url) {
    var m = (url || "").match(/khotruyen\.win\/truyen\/([a-z0-9-]+)\//i);
    var src = m ? shTakeFill(m[1]) : null;
    if (!src) return shMirrorStub([]);
    try {
        var have = {}, min = null, max = null;
        for (var i = 0; i < src.length; i++) {
            var n = parseFloat((src[i].slug || "").replace(/^chuong-/, ""));
            if (isNaN(n)) continue;
            have[n] = true;
            if (Number.isSafeInteger(n)) {
                if (min === null || n < min) min = n;
                if (max === null || n > max) max = n;
            }
        }

        var merged = src.slice();
        if (min !== null) {
            var mirror = shParseMirrorChapters(html, m[1]);
            var added = {};
            for (var j = 0; j < mirror.length; j++) {
                var e = mirror[j];
                if (Math.floor(e.num) !== e.num) continue;   // integers only
                if (e.num <= min || e.num >= max) continue;   // interior only
                if (have[e.num] || added[e.num]) continue;
                added[e.num] = true;
                merged.push({
                    id: e.url,
                    name: "Chapter " + e.numStr,
                    slug: "chuong-" + e.numStr,
                    source: "mirror"
                });
            }
        }
        merged.sort(function (a, b) {
            return parseFloat((a.slug || "").replace(/^chuong-/, "")) -
                   parseFloat((b.slug || "").replace(/^chuong-/, ""));
        });
        return shMirrorStub([{ name: "Server 1", episodes: merged }]);
    } catch (e) {
        return shMirrorStub([{ name: "Server 1", episodes: src }]);
    }
}

function parseDetailResponse(html, url) {
    try {
        // v3.2.0: a filled chapter's reader page lives on the
        // mirror; its images are plain <img> tags on the family
        // CDN (verified live: full-size strips, served with or
        // without a Referer — the mirror's own is sent anyway).
        if (shIsMirrorUrl(url)) {
            var mImages = [];
            var mTagRegex = /<img[^>]*>/gi;
            var mTag;
            while ((mTag = mTagRegex.exec(html)) !== null) {
                var mSrc = mTag[0].match(/src=["'](https:\/\/image\.shtcdn\.top\/[^"']+)["']/i) ||
                    mTag[0].match(/data-src=["'](https:\/\/image\.shtcdn\.top\/[^"']+)["']/i);
                if (mSrc) {
                    var mUrl = mSrc[1].replace(/&amp;/g, "&");
                    if (mImages.indexOf(mUrl) === -1) mImages.push(mUrl);
                }
            }
            return JSON.stringify({
                images: mImages,
                headers: {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    "Referer": MIRROR + "/"
                }
            });
        }
        var images = [];
        // Reader images are bare <img> tags on the signed CDN host
        // (verified shape, incl. the token query — kept verbatim,
        // only &amp; is unescaped back to &).
        var tagRegex = /<img[^>]*>/gi;
        var tag;
        while ((tag = tagRegex.exec(html)) !== null) {
            var srcMatch = tag[0].match(/src=["'](https:\/\/cdn\.pubtranxzyzz\.store\/[^"']+)["']/i) ||
                tag[0].match(/data-src=["'](https:\/\/cdn\.pubtranxzyzz\.store\/[^"']+)["']/i);
            if (srcMatch) {
                var url = srcMatch[1].replace(/&amp;/g, "&");
                if (images.indexOf(url) === -1) images.push(url);
            }
        }

        return JSON.stringify({
            images: images,
            headers: {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Referer": "https://sayhentai.cx/"
            }
        });
    } catch (e) {
        return "{}";
    }
}

function parseCategoriesResponse(html) {
    var categories = [];
    var seen = {};
    var catRegex = /<a[^>]+href="https:\/\/sayhentai\.cx\/genre\/([a-z0-9-]+)"[^>]*>([\s\S]*?)<\/a>/gi;
    var m;
    while ((m = catRegex.exec(html)) !== null) {
        if (/^\d+$/.test(m[1]) && m[1] !== "18") continue;
        var name = PluginUtils.cleanText(m[2]).replace(/\(\d[\d,.]*\)\s*$/, "").trim();
        if (name && !seen[m[1]]) {
            seen[m[1]] = true;
            categories.push({ name: name, slug: "genre/" + m[1] });
        }
    }
    return JSON.stringify(categories);
}

function parseCountriesResponse(html) { return "[]"; }
function parseYearsResponse(html) { return "[]"; }
