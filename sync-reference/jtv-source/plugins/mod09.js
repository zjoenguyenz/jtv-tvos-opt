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
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "sayhentai",
        "name": "SayHentai",
        "version": "3.1.0",
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

function parseMovieDetail(html) {
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
        for (var j = 0; j < chapters.length; j++) delete chapters[j].num;

        var servers = [{
            name: "Server 1",
            episodes: chapters
        }];

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

function parseDetailResponse(html) {
    try {
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
