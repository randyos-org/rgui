# rgui

Randy's GUI library

## Fonts

Third-party fonts (e.g. Nerd Fonts) are fetched as `build.zig.zon`
dependencies rather than tracked as binary files in this repo. `zig build`
stages the ones currently in use into `zig-out/fonts/` automatically - no
separate step needed.

To vendor another font this way:

1. Find a direct download URL for the font file, or for an archive
   containing it - GitHub release assets work well. Prefer a
   `.tar.gz`/`.tar.xz` asset over a `.zip` when a project publishes both:
   Zig's package fetcher handles tarballs natively, and they're usually much
   smaller (nerd-fonts' per-family `.tar.xz` is roughly 20x smaller than its
   `.zip`, for example).
2. From this directory, run:

   ```sh
   zig fetch --save=<dependency_name> <url>
   ```

   This downloads the archive, hashes it, and appends a
   `.<dependency_name> = .{ .url = ..., .hash = ... }` entry to
   `build.zig.zon` - no need to compute the hash by hand.
3. Add a `Font` value to [`build/fonts.zig`](build/fonts.zig) naming that
   dependency and the path of the desired file inside it (extract the
   archive, or run `tar -tf <the archive>`, to see what's in there).
4. Pass it to `addFont` in [`build/__root__.zig`](build/__root__.zig) and
   `dependOn` the returned step from `b.getInstallStep()`, same as the
   existing Nerd Font entry.
