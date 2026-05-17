#!/usr/bin/env node
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const assets = join(root, "assets");
const framesDir = join(assets, ".frames");
mkdirSync(assets, { recursive: true });
rmSync(framesDir, { recursive: true, force: true });
mkdirSync(framesDir, { recursive: true });

const rows = [
  { action: "stay", profile: "Layth08", wk: 43, h5: 100, status: "ready", selected: true },
  { action: "use", profile: "Layth48", wk: 76, h5: 86, status: "ready" },
  { action: "use", profile: "Layth18", wk: 64, h5: 31, status: "ready" },
  { action: "cap", profile: "Layth38", wk: 0, h5: 100, status: "old cap" },
  { action: "cap", profile: "Layth", wk: 0, h5: 100, status: "cap" },
  { action: "cap", profile: "Layth.qassem", wk: 0, h5: 100, status: "cap" },
  { action: "cap", profile: "Layth28", wk: 0, h5: 100, status: "cap" },
  { action: "login", profile: "current", wk: null, h5: null, status: "login needed" },
];

const palette = {
  bg: "#101112",
  row: "#292929",
  panel: "#232323",
  title: "#ffb07a",
  muted: "#8c8c8c",
  fg: "#efefef",
  active: "#b994ff",
  good: "#a7e3a0",
  warn: "#ffb77e",
  bad: "#ff7086",
};

function esc(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function toneForAction(action) {
  if (action === "stay") return "active";
  if (action === "use") return "good";
  if (action === "cap") return "bad";
  if (action === "login") return "warn";
  return "muted";
}

function toneForMetric(value) {
  if (value == null) return "muted";
  if (value <= 0) return "bad";
  if (value < 50) return "warn";
  return "good";
}

function toneForStatus(status) {
  if (status === "ready") return "good";
  if (status === "old cap") return "warn";
  if (status === "cap") return "bad";
  return "muted";
}

function text(x, y, value, cls = "fg", attrs = "") {
  return `<text x="${x}" y="${y}" class="${cls}" ${attrs}>${esc(value)}</text>`;
}

function metric(x, y, value, width = 150) {
  const labelX = x + 26;
  const barX = x + 56;
  const barW = width - 56;
  const tone = toneForMetric(value);
  if (value == null) {
    return text(labelX, y, "-", "muted", 'text-anchor="middle"');
  }
  const fillW = Math.max(0, Math.min(barW, Math.round((value / 100) * barW)));
  const parts = [
    text(labelX, y, value, tone, 'text-anchor="middle"'),
    `<rect x="${barX}" y="${y - 16}" width="${barW}" height="32" class="bar-bg"/>`,
    `<rect x="${barX}" y="${y - 16}" width="${barW}" height="2" class="bar-rule"/>`,
    `<rect x="${barX}" y="${y + 14}" width="${barW}" height="2" class="bar-rule"/>`,
  ];
  if (fillW > 0) {
    parts.splice(2, 0, `<rect x="${barX}" y="${y - 16}" width="${fillW}" height="32" class="bar-${tone}"/>`);
  }
  return parts.join("\n");
}

function visibleRows(selected, scrolled) {
  if (!scrolled) return rows;
  return rows.slice(1);
}

function renderFrame({ selected = 0, scrolled = false, exit = false } = {}) {
  if (exit) {
    return `<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="420" viewBox="0 0 1120 420">
  <rect width="1120" height="420" fill="${palette.bg}"/>
  <style>${style()}</style>
  ${text(30, 40, "Auth · Codex profiles", "title")}
  ${text(30, 94, "escaped selector, stayed on active profile", "muted")}
  ${text(30, 152, "$ codex-auth usage --refresh --select", "fg")}
  ${text(30, 196, "$", "title")}
</svg>`;
  }

  const list = visibleRows(selected, scrolled);
  const selectedProfile = rows[selected]?.profile;
  const body = [];
  body.push(`<rect width="1120" height="420" fill="${palette.bg}"/>`);
  body.push(`<style>${style()}</style>`);
  body.push(text(30, 24, "Auth · Codex profiles", "title"));
  body.push(text(404, 24, "enter select · esc stay", "muted"));
  body.push(text(58, 66, "act", "muted", 'text-anchor="middle"'));
  body.push(text(180, 66, "profile", "muted", 'text-anchor="middle"'));
  body.push(text(462, 66, "wk%", "muted", 'text-anchor="middle"'));
  body.push(text(690, 66, "5h%", "muted", 'text-anchor="middle"'));
  body.push(text(976, 66, "status", "muted", 'text-anchor="middle"'));
  body.push(text(0, 102, "filter", "warn", 'font-weight="700"'));

  list.forEach((row, index) => {
    const y = 140 + index * 34;
    const isSelected = row.profile === selectedProfile;
    if (isSelected) {
      body.push(`<rect x="0" y="${y - 18}" width="1120" height="34" class="row-selected"/>`);
    }
    body.push(text(30, y, row.action, toneForAction(row.action), row.action === "stay" || row.action === "cap" ? 'font-weight="700"' : ""));
    body.push(text(140, y, row.profile, "fg", isSelected ? 'font-weight="700"' : ""));
    body.push(metric(392, y, row.wk));
    body.push(metric(638, y, row.h5));
    body.push(text(928, y, row.status, toneForStatus(row.status), row.status === "ready" && isSelected ? 'font-weight="700"' : ""));
  });

  return `<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="420" viewBox="0 0 1120 420">
${body.join("\n")}
</svg>`;
}

function style() {
  return `
    text { font-family: "DejaVu Sans Mono", "SFMono-Regular", Consolas, monospace; font-size: 25px; dominant-baseline: middle; }
    .title { fill: ${palette.title}; }
    .muted { fill: ${palette.muted}; }
    .fg { fill: ${palette.fg}; }
    .active { fill: ${palette.active}; }
    .good { fill: ${palette.good}; }
    .warn { fill: ${palette.warn}; }
    .bad { fill: ${palette.bad}; }
    .row-selected { fill: ${palette.row}; }
    .bar-bg { fill: ${palette.panel}; }
    .bar-good { fill: ${palette.good}; }
    .bar-warn { fill: ${palette.warn}; }
    .bar-bad { fill: ${palette.bad}; }
    .bar-muted { fill: ${palette.muted}; }
    .bar-rule { fill: ${palette.bg}; }
  `;
}

const staticSvg = renderFrame({ selected: 0, scrolled: false });
writeFileSync(join(assets, "usage-selector.svg"), staticSvg);
execFileSync("convert", [join(assets, "usage-selector.svg"), join(assets, "usage-selector.png")]);

const sequence = [
  ...Array(5).fill({ selected: 0, scrolled: false }),
  ...Array(2).fill({ selected: 1, scrolled: false }),
  ...Array(2).fill({ selected: 2, scrolled: false }),
  ...Array(2).fill({ selected: 3, scrolled: false }),
  ...Array(2).fill({ selected: 4, scrolled: true }),
  ...Array(2).fill({ selected: 5, scrolled: true }),
  ...Array(2).fill({ selected: 6, scrolled: true }),
  ...Array(3).fill({ selected: 7, scrolled: true }),
  ...Array(5).fill({ exit: true }),
];

sequence.forEach((frame, index) => {
  const svgPath = join(framesDir, `frame-${String(index).padStart(2, "0")}.svg`);
  writeFileSync(svgPath, renderFrame(frame));
});

execFileSync("ffmpeg", [
  "-y",
  "-hide_banner",
  "-loglevel",
  "error",
  "-framerate",
  "5",
  "-i",
  join(framesDir, "frame-%02d.svg"),
  "-vf",
  "fps=5,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
  "-loop",
  "0",
  join(assets, "usage-selector.gif"),
]);
rmSync(framesDir, { recursive: true, force: true });
