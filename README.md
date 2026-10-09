# TXelHtml — HTML + CSS rendering component for Lazarus

`TXelHtml` is a visual Lazarus component (palette page **Xelitan**) that shows web pages.
It is written in pure Object Pascal: it parses HTML and CSS, lays the page out and paints
it itself — no browser engine, no WebView, no OpenSSL or zlib DLLs.

# Requirements:
- HTTPS is done through [TlsLib4Pascal](https://github.com/Xor-el/TlsLib4Pascal) (TLS 1.2/1.3,
  pure Pascal); server certificates are verified against the Windows certificate store.
- XelImageFormats - to render .webp images

[image](/_demo/demo_acid1.png)

# Features

The viewer passes ACID1 and ACID2 tests, can load many websites just as well as Firefox or Chrome.

- supports local files, http, https
- supports fonts in WOFF, WOFF2, TTF, OTF and SVG formats
- loads images in threads
- supports gif, jpeg, png and webp images

# Systems?

Windows and Linux GTK2
