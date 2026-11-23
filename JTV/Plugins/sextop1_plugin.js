// =============================================================================
// Sextop1 v2.0.2 — rewritten 2026-11-14 for the site's new home
// sextop1.cash (WordPress "top1tube" theme). The old vnsextop1.com
// markup is gone entirely; this parser targets the new theme.
// Playback: watch page carries a post id (.mb-screen data-id);
// GET /wp-json/sextop1/player/?id=<postId>&server=<n> returns a
// JWPlayer setup whose source is a DIRECT .m3u8 hosted on the site
// itself — no embed hop needed at playback time.
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "sextop1",
        "name": "Sextop1",
        "version": "2.0.3",
        "baseUrl": "https://sextop1.cash",
        "iconUrl": "https://sextop1.cash/favicon.ico",
        "isEnabled": true,
        "isAdult": true,
        "type": "VIDEO",
        "playerType": "native",
        "layoutType": "HORIZONTAL"
    });
}

function getHomeSections() {
    return JSON.stringify([
        { slug: 'phim-sex-viet-sub', title: 'Vietsub', type: 'Horizontal', path: 'category' },
        { slug: 'jav', title: 'Phim JAV', type: 'Horizontal', path: 'category' },
        { slug: 'phim-sex-khong-che', title: 'Không Che', type: 'Horizontal', path: 'category' },
        { slug: 'phim-sex-trung-quoc', title: 'Trung Quốc', type: 'Horizontal', path: 'category' },
        { slug: 'home', title: 'Mới Cập Nhật', type: 'Grid', path: '' }
    ]);
}

function getPrimaryCategories() {
    return JSON.stringify([
        { name: 'Vietsub', slug: 'phim-sex-viet-sub' },
        { name: 'JAV', slug: 'jav' },
        { name: 'Không che', slug: 'phim-sex-khong-che' },
        { name: 'Trung Quốc', slug: 'phim-sex-trung-quoc' },
        { name: 'Châu Âu', slug: 'phim-sex-chau-au' },
        { name: 'HD', slug: 'phim-sex-hd' },
        { name: 'Loạn luân', slug: 'phim-sex-loan-luan' },
        { name: 'Hiếp dâm', slug: 'phim-sex-hiep-dam' }
    ]);
}

function getFilterConfig() {
    return JSON.stringify({});
}

// =============================================================================
// URL GENERATION
// =============================================================================

var ST1_BASE = "https://sextop1.cash";

function getUrlList(slug, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;

    if (slug === '' || slug === 'home') {
        if (page > 1) return ST1_BASE + "/page/" + page + "/";
        return ST1_BASE + "/";
    }
    var url = ST1_BASE + "/category/" + slug + "/";
    if (page > 1) url += "page/" + page + "/";
    return url;
}

function getUrlSearch(keyword, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    var url = ST1_BASE + "/?s=" + encodeURIComponent(keyword);
    if (page > 1) url += "&paged=" + page;
    return url;
}

// episode.id / item.id = full watch-page URL (may carry #s<server>)
function getUrlDetail(slug) {
    if (!slug) return "";
    if (slug.indexOf("http") === 0) return slug;
    if (slug.charAt(0) !== '/') slug = '/' + slug;
    return ST1_BASE + slug;
}

function getUrlCategories() { return ""; }
function getUrlCountries() { return ""; }
function getUrlYears() { return ""; }

// =============================================================================
// LIST PARSING — <article class="card"> blocks (home / category / search
// all share this markup on the new theme)
// =============================================================================

function st1Clean(text) {
    return (text || "").replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&#039;/g, "'").replace(/&quot;/g, '"').trim();
}

function parseListResponse(html) {
    var items = [];
    var blocks = html.split(/<article[^>]*class=["'][^"']*\bcard\b[^"']*["'][^>]*>/i);

    for (var i = 1; i < blocks.length; i++) {
        var block = blocks[i].slice(0, 4000);

        var linkMatch = block.match(/<h2[^>]*class=["'][^"']*card-title[^"']*["'][^>]*>\s*<a[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/i);
        if (!linkMatch) continue;
        var link = linkMatch[1];
        var title = st1Clean(linkMatch[2]);
        if (!title) {
            var altMatch = block.match(/<img[^>]*alt=["']([^"']+)["']/i);
            if (altMatch) title = st1Clean(altMatch[1]);
        }

        var thumb = "";
        var imgMatch = block.match(/<img[^>]*class=["'][^"']*top1tube-thumb[^"']*["'][^>]*>/i);
        if (imgMatch) {
            var srcMatch = imgMatch[0].match(/[\s]src=["']([^"']+)["']/i);
            var dataMatch = imgMatch[0].match(/data-src=["']([^"']+)["']/i);
            if (srcMatch && srcMatch[1].indexOf("data:image") !== 0) thumb = srcMatch[1];
            else if (dataMatch) thumb = dataMatch[1];
        }

        if (link && title) {
            items.push({
                id: link,
                title: title,
                posterUrl: thumb,
                backdropUrl: thumb,
                year: 0
            });
        }
    }

    var currentPage = 1;
    var cpMatch = html.match(/class=["'][^"']*(?:current|active)[^"']*["'][^>]*>\s*(\d+)\s*</i);
    if (cpMatch) currentPage = parseInt(cpMatch[1]);

    var totalPages = currentPage;
    var lpRegex = /\/page\/(\d+)\//gi;
    var lpMatch;
    while ((lpMatch = lpRegex.exec(html)) !== null) {
        var pageNum = parseInt(lpMatch[1]);
        if (pageNum > totalPages) totalPages = pageNum;
    }

    return JSON.stringify({
        items: items,
        pagination: {
            currentPage: currentPage,
            totalPages: totalPages
        }
    });
}

function parseSearchResponse(html) {
    return parseListResponse(html);
}

// =============================================================================
// DETAIL — watch page → one episode per server button (#s<n>)
// =============================================================================

function parseMovieDetail(html) {
    try {
        var titleMatch = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
        var title = titleMatch ? st1Clean(titleMatch[1]) : "";

        var ogImg = html.match(/<meta[^>]*property=["']og:image["'][^>]*content=["']([^"']+)["']/i);
        var posterUrl = ogImg ? ogImg[1] : "";

        var ogDesc = html.match(/<meta[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']/i);
        var description = ogDesc ? st1Clean(ogDesc[1]) : "";

        var pageUrl = "";
        var ogUrl = html.match(/<meta[^>]*property=["']og:url["'][^>]*content=["']([^"']+)["']/i);
        if (ogUrl) pageUrl = ogUrl[1];

        var categoriesArr = [];
        var catRegex = /href=["'][^"']*\/category\/[^"']*["'][^>]*>([^<]+)<\/a>/gi;
        var cm;
        var seenCat = {};
        while ((cm = catRegex.exec(html)) !== null) {
            var cname = st1Clean(cm[1]);
            if (cname && !seenCat[cname]) { seenCat[cname] = true; categoriesArr.push(cname); }
        }

        // Server buttons: elements with class "server" + data-server="n"
        var serverIds = [];
        var srvRegex = /class=["'][^"']*\bserver\b[^"']*["'][^>]*data-server=["'](\d+)["']/gi;
        var sm;
        while ((sm = srvRegex.exec(html)) !== null) {
            if (serverIds.indexOf(sm[1]) === -1) serverIds.push(sm[1]);
        }
        var srvRegex2 = /data-server=["'](\d+)["'][^>]*class=["'][^"']*\bserver\b[^"']*["']/gi;
        while ((sm = srvRegex2.exec(html)) !== null) {
            if (serverIds.indexOf(sm[1]) === -1) serverIds.push(sm[1]);
        }
        if (serverIds.length === 0) serverIds = ["1"];
        serverIds.sort();

        var servers = [];
        for (var s = 0; s < serverIds.length; s++) {
            var sid = serverIds[s];
            servers.push({
                name: "Server #" + sid,
                episodes: [{
                    id: (pageUrl || "") + "#s" + sid,
                    name: "Full",
                    slug: "full-s" + sid
                }]
            });
        }

        return JSON.stringify({
            id: "",
            title: title,
            posterUrl: posterUrl,
            backdropUrl: posterUrl,
            description: description,
            servers: servers,
            category: categoriesArr.join(", "),
            status: "Full"
        });
    } catch (e) {
        return "null";
    }
}

// =============================================================================
// STREAM RESOLUTION (watch page → player API → direct m3u8)
// =============================================================================

// parseDetailResponse: watch-page HTML in → player-API config out.
// The post id lives on .mb-screen's data-id; the server comes from
// the episode's #s<n> fragment.
function parseDetailResponse(html, fetchedUrl) {
    try {
        var idMatch = html.match(/mb-screen[^>]*data-id=["'](\d+)["']/i)
            || html.match(/data-id=["'](\d+)["'][^>]*mb-screen/i)
            || html.match(/postid-(\d+)/i)
            || html.match(/<article[^>]*id=["']post-(\d+)["']/i);
        if (!idMatch) {
            return JSON.stringify({ url: "", isEmbed: false, headers: {} });
        }
        var serverId = "1";
        if (fetchedUrl) {
            var fragMatch = fetchedUrl.match(/#s(\d+)/);
            if (fragMatch) serverId = fragMatch[1];
        }
        return JSON.stringify({
            url: ST1_BASE + "/wp-json/sextop1/player/?id=" + idMatch[1] + "&server=" + serverId,
            isEmbed: true,
            headers: { "Referer": ST1_BASE + "/" }
        });
    } catch (error) {
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    }
}

// parseEmbedResponse: player-API JSON in → direct stream out.
// Response: {"success":true,"data":"...jwplayer setup with
// sources: [{file: 'https://.../NNNN.m3u8', type: 'hls'}]..."}
function parseEmbedResponse(html, url) {
    try {
        var cleaned = (html || "").replace(/\\\//g, '/');
        var fileMatch = cleaned.match(/file:\s*['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/i)
            || cleaned.match(/file:\s*['"](https?:\/\/[^'"]+\.(?:mp4|vl)[^'"]*)['"]/i);
        if (fileMatch) {
            return JSON.stringify({
                url: fileMatch[1],
                isEmbed: false,
                headers: { "Referer": ST1_BASE + "/" }
            });
        }
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    } catch (error) {
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    }
}
