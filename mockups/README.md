# Bridge — color scheme mockup

`bridge-colors.svg` is a MacBook Pro 14" (1512×982) mockup exploring a new
color scheme for the Bridge multi-agent orchestration surface. It renders the
same orchestration card in six combinations of a palette sampled from a
risograph print.

## Palette
- coral  `#F9573C`
- cobalt `#2F39A6`
- purple `#5E5570`
- olive  `#9A8A4E`
- (derived neutrals: ink `#1E1B2E`, cream `#F2EEE2`)

## Regenerate
```
python3 gen_mockup.py            # writes bridge-colors.svg
# optional raster preview:
python3 -c "import cairosvg; cairosvg.svg2png(url='bridge-colors.svg', write_to='preview.png', output_width=1512, output_height=982)"
```
