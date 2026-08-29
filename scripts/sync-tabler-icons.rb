#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sync-tabler-icons.rb — copies the Tabler SVGs we actually use into the
# DiskJockeyApplication asset catalog as imagesets, so SwiftUI can render
# them as templates with `.foregroundStyle(...)` tinting.
#
# Run any time the SF Symbol → Tabler mapping below changes. Idempotent —
# regenerates the imagesets in place. Does NOT touch project.pbxproj
# (the asset catalog folder reference is enough; new imagesets inside
# are auto-discovered by Xcode at build time).

require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require 'tmpdir'

ROOT = File.expand_path(File.join(__dir__, '..'))

# The Tabler release this project's icons come from. Pinned rather than
# tracking the default branch: an icon that changes shape under us would
# silently alter the app's appearance on the next run of this script.
TABLER_TAG = ENV.fetch('TABLER_TAG', 'v3.44.0')

# Fetched, not vendored.
#
# This used to read `vendor/tabler-icons/icons`, a 73 MB submodule
# carrying the entire icon set — around 5,900 SVGs — so that this script
# could read the 46 named in MAPPING below. That is about 70 KB of actual
# need.
#
# The fetch happens only when the mapping changes, and its output is the
# imagesets committed under DiskJockeyApplication/Assets.xcassets, so a
# normal build never touches the network. A missing icon is reported by
# name, the same as it was when the directory was local.
#
# Tabler is MIT; the attribution in THIRD_PARTY_LICENSES.md stands either
# way, because the icons ship inside the app.
TABLER_BASE = "https://raw.githubusercontent.com/tabler/tabler-icons/#{TABLER_TAG}/icons"

def fetch_svg(style, basename)
  uri = URI("#{TABLER_BASE}/#{style}/#{basename}.svg")
  res = Net::HTTP.get_response(uri)
  return nil unless res.is_a?(Net::HTTPSuccess)
  res.body
rescue StandardError => e
  warn "  fetch failed for #{style}/#{basename}.svg: #{e.class}: #{e.message}"
  nil
end

# Written to a scratch directory so the rest of the script keeps taking a
# path, and so one icon used twice is fetched once.
FETCH_CACHE = {}
def local_copy(dir, style, basename)
  key = "#{style}/#{basename}"
  return FETCH_CACHE[key] if FETCH_CACHE.key?(key)
  body = fetch_svg(style, basename)
  path = nil
  if body
    path = File.join(dir, "#{style}-#{basename}.svg")
    File.write(path, body)
  end
  FETCH_CACHE[key] = path
end
ASSETS_DIR = File.join(ROOT, 'DiskJockeyApplication', 'Assets.xcassets')

# SF Symbol → [tabler_style, tabler_basename]. The Tabler basename is the
# .svg filename without extension. Add new entries here when you start
# using a new SF Symbol elsewhere in the UI.
MAPPING = {
  'arrow.triangle.2.circlepath'           => ['outline', 'refresh'],
  'bolt.horizontal.circle.fill'           => ['filled',  'bolt'],
  'checkmark.circle.fill'                 => ['filled',  'circle-check'],
  'checkmark.seal.fill'                   => ['filled',  'rosette'],
  'cloud'                                 => ['outline', 'cloud'],
  'cube.box'                              => ['outline', 'cube'],
  'doc.text.magnifyingglass'              => ['outline', 'file-search'],
  'eject'                                 => ['outline', 'player-eject'],
  'exclamationmark.triangle.fill'         => ['filled',  'alert-triangle'],
  'externaldrive'                         => ['outline', 'device-sd-card'],
  'externaldrive.badge.minus'             => ['outline', 'device-sd-card'],
  'externaldrive.badge.plus'              => ['outline', 'device-sd-card'],
  'externaldrive.badge.questionmark'      => ['outline', 'device-sd-card'],
  'externaldrive.connected.to.line.below' => ['outline', 'usb'],
  'externaldrive.fill'                    => ['outline', 'device-sd-card'],
  'folder'                                => ['outline', 'folder'],
  'folder.badge.plus'                     => ['outline', 'folder-plus'],
  'hourglass'                             => ['outline', 'hourglass'],
  'internaldrive'                         => ['outline', 'server'],
  'internaldrive.fill'                    => ['outline', 'server'],
  'line.3.horizontal.decrease.circle'     => ['outline', 'filter'],
  'lock.fill'                             => ['filled',  'lock'],
  'lock.shield'                           => ['outline', 'shield-lock'],
  'minus.circle'                          => ['outline', 'circle-minus'],
  'network'                               => ['outline', 'network'],
  'pencil.circle.fill'                    => ['filled',  'pencil'],
  'plus'                                  => ['outline', 'plus'],
  'questionmark.circle'                   => ['outline', 'help-circle'],
  'questionmark.square.dashed'            => ['outline', 'help-square'],
  'rectangle.split.3x1'                   => ['outline', 'layout-rows'],
  'shippingbox'                           => ['outline', 'package'],
  'square.and.arrow.up'                   => ['outline', 'share'],
  'square.grid.3x3'                       => ['outline', 'layout-grid'],
  'square.grid.3x3.fill'                  => ['filled',  'layout-grid'],
  'terminal'                              => ['outline', 'terminal-2'],
  'trash'                                 => ['outline', 'trash'],
  'xmark.octagon.fill'                    => ['filled',  'circle-x'],
}.freeze

# Asset-name → [tabler_style, tabler_basename] for non-SF-Symbol icons
# (the OS-brand glyphs we used to hand-draw because SF Symbols won't
# ship them). Output filename is the asset name verbatim.
EXTRAS = {
  'tabler-linux-drive'    => ['outline', 'brand-ubuntu'],
  'tabler-windows-drive'  => ['outline', 'brand-windows'],
  'tabler-sidebar-toggle' => ['outline', 'layout-sidebar-left-collapse'],
  'tabler-dismiss'        => ['outline', 'x'],
  'tabler-brand-onedrive'     => ['outline', 'brand-onedrive'],
  'tabler-brand-filezilla'    => ['outline', 'brand-filezilla'],
  'tabler-brand-dropbox'      => ['outline', 'brand-dropbox'],
  'tabler-brand-google-drive' => ['outline', 'brand-google-drive'],
  'tabler-brand-windows'      => ['outline', 'brand-windows'],
}.freeze

# Asset name == SF Symbol name, with `.fill` preserved so call-site
# semantics survive — `.fill` SF Symbols become `tabler-…-fill`.
def asset_name_for(sf_symbol)
  base = sf_symbol.gsub('.', '-')
  "tabler-#{base}"
end

def write_imageset(asset_name, svg_src)
  imageset = File.join(ASSETS_DIR, "#{asset_name}.imageset")
  FileUtils.mkdir_p(imageset)
  svg_dst = File.join(imageset, "#{asset_name}.svg")
  FileUtils.cp(svg_src, svg_dst)
  contents = {
    'images' => [
      { 'filename' => "#{asset_name}.svg", 'idiom' => 'universal' }
    ],
    'info' => { 'author' => 'xcode', 'version' => 1 },
    'properties' => {
      'preserves-vector-representation' => true,
      'template-rendering-intent' => 'template'
    }
  }
  File.write(File.join(imageset, 'Contents.json'),
             JSON.pretty_generate(contents) + "\n")
end

missing = []
created = 0
scratch = Dir.mktmpdir('tabler-icons')
at_exit { FileUtils.remove_entry(scratch) if File.directory?(scratch) }

puts "Fetching Tabler icons at #{TABLER_TAG}"

MAPPING.each do |sf_symbol, (style, basename)|
  src = local_copy(scratch, style, basename)
  if src.nil?
    missing << "#{sf_symbol} → #{style}/#{basename}.svg"
    next
  end
  asset = asset_name_for(sf_symbol)
  write_imageset(asset, src)
  created += 1
end

EXTRAS.each do |asset, (style, basename)|
  src = local_copy(scratch, style, basename)
  if src.nil?
    missing << "#{asset} → #{style}/#{basename}.svg"
    next
  end
  write_imageset(asset, src)
  created += 1
end

puts "[tabler] wrote #{created} imageset(s) under #{ASSETS_DIR}"
unless missing.empty?
  warn "[tabler] MISSING SOURCES (no Tabler SVG found):"
  missing.each { |m| warn "  - #{m}" }
  exit 1
end
