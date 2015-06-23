using Celeste
using CelesteTypes

using DataFrames
using SampleData

import SDSS
import PSF
import FITSIO
import PyPlot

# Some examples of the SDSS fits functions.
field_dir = joinpath(dat_dir, "sample_field")
run_num = "003900"
camcol_num = "6"
field_num = "0269"

const band_letters = ['u', 'g', 'r', 'i', 'z']

b = 1
b_letter = band_letters[b]

#############
# Load the catalog

# In python:
# 
# from tractor.sdss import *
# sdss = DR8()
# sdss.get_url('photoObj', args.run, args.camcol, args.field)

blob = SDSS.load_sdss_blob(field_dir, run_num, camcol_num, field_num);
cat_df = SDSS.load_catalog_df(field_dir, run_num, camcol_num, field_num);
cat_entries = SDSS.convert_catalog_to_celeste(cat_df, blob);
cat_coords = convert(Array{Float64}, cat_df[[:ra, :dec]])'

# Write pixel coordinates to the catalog
for b=1:5
	pix_coords = WCSLIB.wcss2p(blob[b].wcs, cat_coords)
	cat_df[symbol("pix_x_$(b)")] = pix_coords[1,:][:]
	cat_df[symbol("pix_y_$(b)")] = pix_coords[2,:][:]
end
writetable("/tmp/catalog-$run_num-$camcol_num-$field_num.csv", cat_df)

# Write to csv for easy viewing.
for b=1:5
	b_letter = band_letters[b]
	writedlm("/tmp/frame-$b_letter-$run_num-$camcol_num-$field_num.csv", blob[b].pixels, ',')
end


#######################
# WCS stuff.  See
# https://github.com/JuliaAstro/FITSIO.jl/issues/39

b = 1
b_letter = band_letters[b]
@assert 1 <= b <= 5
b_letter = band_letters[b]

# A bug in my FITSIO change:
img_filename = "$field_dir/frame-$b_letter-$run_num-$camcol_num-$field_num.fits"
img_fits = FITSIO.FITS(img_filename)
ctype = [FITSIO.read_key(img_fits[1], "CTYPE1")[1], FITSIO.read_key(img_fits[1], "CTYPE2")[1]]
foo = read_header(img_fits[1]);
bar = read_header(img_fits[2]);
header_str = FITSIO.read_header(img_fits[1], ASCIIString)
close(img_fits)

world_coords = Array(Float64, 2, nrow(cat_df))
for n=1:nrow(cat_df)
	world_coords[1, n] = cat_df[n, :ra]
	world_coords[2, n] = cat_df[n, :dec]
end
H = blob[b].H
W = blob[b].W
pixcrd = Float64[0 0; 0 H; 0 W; H W]'

WCSLIB.wcss2p(blob[b].wcs, world_coords)'

[ unsafe_load(blob[b].wcs.crval, i) for i=1:2 ]
[ unsafe_load(blob[b].wcs.cd, i) for i=1:4 ]


# Other way to read it in?  This doesn't seem to work.
naxis = FITSIO.read_key(img_fits[1], "NAXIS")[1]
@assert naxis == 2

ctype = [FITSIO.read_key(img_fits[1], "CTYPE1")[1], FITSIO.read_key(img_fits[1], "CTYPE2")[1]]
crpix = [FITSIO.read_key(img_fits[1], "CRPIX1")[1], FITSIO.read_key(img_fits[1], "CRPIX2")[1]]
crval = [FITSIO.read_key(img_fits[1], "CRVAL1")[1], FITSIO.read_key(img_fits[1], "CRVAL2")[1]]
cunit = [FITSIO.read_key(img_fits[1], "CUNIT1")[1], FITSIO.read_key(img_fits[1], "CUNIT2")[1]]

cd = [ FITSIO.read_key(img_fits[1], "CD1_1")[1] FITSIO.read_key(img_fits[1], "CD1_2")[1];
       FITSIO.read_key(img_fits[1], "CD2_1")[1] FITSIO.read_key(img_fits[1], "CD2_2")[1] ]

# Oh well, this doesn't work.
w2 = WCSLIB.wcsprm(naxis;
		            cd = cd,
		            ctype = ctype,
		            crpix = crpix,
		            crval = crval)

[ unsafe_load(w2.crval, i) for i=1:2 ]

H = blob[b].H
W = blob[b].W

pixcrd = Float64[0 0; 0 H; 0 W; H W]'

# convert pixel -> world coordinates
world1 = WCSLIB.wcsp2s(w2, pixcrd)
world2 = WCSLIB.wcsp2s(wcs, pixcrd)

# convert world -> pixel coordinates
pixcrd12 = WCSLIB.wcss2p(w2, world1)
pixcrd22 = WCSLIB.wcss2p(wcs, world2)

