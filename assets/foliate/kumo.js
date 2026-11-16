// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The bridge between foliate-js and Dart. Dart decides everything worth
// keeping — where the book was left, the theme, the font size — and this
// page only renders and reports. It is served by the app itself on
// 127.0.0.1 (lib/features/books/reader_server.dart), with the book beside it.
//
// Dart → page: window.kumo.next(), .prev(), .goToFraction(f), .goTo(href),
//              .setStyle({...}), .setFlow('paginated' | 'scrolled')
// Page → Dart: Kumo.postMessage({name: 'ready' | 'relocate' | 'tap' |
//              'failed', args}) through webview_flutter's channel.

import './view.js'

const params = new URLSearchParams(location.search)

const send = (name, args = null) => {
    try {
        window.Kumo?.postMessage(JSON.stringify({ name, args }))
    } catch (e) {
        console.error(e)
    }
}

let style = {
    fontSize: 100,
    lineHeight: 1.5,
    margin: 6,
    background: '#ffffff',
    foreground: '#000000',
    link: '#1a5fb4',
    justify: true,
    font: '',
}

const css = s => `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color: ${s.foreground} !important;
        background: ${s.background} !important;
        font-size: ${s.fontSize}% !important;
    }
    body {
        color: inherit !important;
        background: transparent !important;
        ${s.font ? `font-family: ${s.font} !important;` : ''}
    }
    a:link, a:visited { color: ${s.link} !important; }
    p, li, blockquote, dd {
        line-height: ${s.lineHeight} !important;
        text-align: ${s.justify ? 'justify' : 'start'};
        hyphens: auto;
        -webkit-hyphens: auto;
        widows: 2;
        orphans: 2;
    }
    [align="left"] { text-align: left; }
    [align="right"] { text-align: right; }
    [align="center"] { text-align: center; }
    pre { white-space: pre-wrap !important; }
    img, svg { max-width: 100%; height: auto; }
    aside[epub|type~="footnote"], aside[epub|type~="endnote"],
    aside[epub|type~="note"], aside[epub|type~="rearnote"] {
        display: none;
    }
`

const view = document.createElement('foliate-view')
document.body.append(view)

const applyStyle = () => {
    document.documentElement.style.setProperty('--kumo-bg', style.background)
    document.documentElement.style.setProperty('--kumo-fg', style.foreground)
    view.renderer?.setStyles?.(css(style))
    // Margins are the paginator's, not the book's: a percentage of the width
    // on each side, between the columns.
    view.renderer?.setAttribute('margin', `${Math.round(style.margin * 8)}px`)
    view.renderer?.setAttribute('gap', `${style.margin}%`)
}

// A tap: the outer thirds turn the page, the middle shows the chrome. Taps
// on a link are the link's.
const onTap = (event, doc) => {
    if (event.defaultPrevented) return
    if (event.target?.closest?.('a[href]')) return
    const selection = doc.defaultView?.getSelection()
    if (selection && !selection.isCollapsed) return
    // Paginated, the iframe is several pages wide and scrolled; what counts
    // is where on the screen the finger landed. The frame's rectangle is in
    // this page's coordinates and already moved by the scroll.
    const frame = doc === document ? null : doc.defaultView?.frameElement
    const left = frame ? frame.getBoundingClientRect().left : 0
    const width = window.innerWidth || 1
    const at = Math.min(Math.max((event.clientX + left) / width, 0), 1)
    if (at < 0.28) view.goLeft()
    else if (at > 0.72) view.goRight()
    else send('tap')
}

const onKey = event => {
    switch (event.key) {
        case 'ArrowLeft':
        case 'PageUp':
            view.goLeft(); break
        case 'ArrowRight':
        case 'PageDown':
        case ' ':
            view.goRight(); break
        case 'Enter':
        case 'ArrowUp':
        case 'ArrowDown':
        case 'Escape':
            send('tap'); break
        default:
            return
    }
    event.preventDefault()
}

document.addEventListener('keydown', onKey)
document.addEventListener('click', event => onTap(event, document))

view.addEventListener('load', ({ detail: { doc } }) => {
    doc.addEventListener('keydown', onKey)
    doc.addEventListener('click', event => onTap(event, doc))
})

let lastFraction = null
view.addEventListener('relocate', ({ detail }) => {
    const fraction = typeof detail.fraction === 'number' ? detail.fraction : null
    if (fraction === null) return
    lastFraction = fraction
    send('relocate', {
        fraction,
        chapter: detail.tocItem?.label ?? null,
        page: detail.location?.current ?? null,
        pages: detail.location?.total ?? null,
    })
})

const flatten = (items, depth = 0) => (items ?? []).flatMap(item => [
    { label: (item.label ?? '').trim(), href: item.href ?? null, depth },
    ...flatten(item.subitems, depth + 1),
])

window.kumo = {
    next: () => view.goRight(),
    prev: () => view.goLeft(),
    goToFraction: f => view.goToFraction(Math.min(Math.max(f, 0), 1)),
    goTo: href => view.goTo(href),
    setStyle: next => {
        style = { ...style, ...next }
        applyStyle()
    },
    setFlow: flow => view.renderer?.setAttribute('flow', flow),
    fraction: () => lastFraction,
}

const open = async () => {
    try {
        const s = params.get('style')
        if (s) style = { ...style, ...JSON.parse(s) }
        await view.open(params.get('book'))
        view.renderer.setAttribute('flow', params.get('flow') ?? 'paginated')
        view.renderer.setAttribute('max-inline-size', '720px')
        view.renderer.setAttribute('animated', '')
        applyStyle()

        const start = parseFloat(params.get('start') ?? '')
        if (start > 0) await view.goToFraction(Math.min(start, 1))
        else await view.renderer.next()

        const book = view.book
        send('ready', {
            toc: flatten(book.toc),
            sections: view.getSectionFractions(),
            rtl: book.dir === 'rtl',
        })
    } catch (e) {
        console.error(e)
        send('failed', String(e?.message ?? e))
    }
}

open()
