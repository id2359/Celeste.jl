module SkyImages

using ..Types
import ..SDSSIO
import ..SDSS
import Celeste.PSF

import WCS
import DataFrames
import ..ElboDeriv # For stitch_object_tiles
import FITSIO

import Base.convert

export load_stamp_blob, crop_image!,
       convert_catalog_to_celeste, load_stamp_catalog,
       break_blob_into_tiles, break_image_into_tiles,
       get_local_sources, stitch_object_tiles


"""
Convert from a catalog in dictionary-of-arrays, as returned by
SDSSIO.read_photoobj to Vector{CatalogEntry}.
"""
function convert(::Type{Vector{CatalogEntry}}, catalog::Dict{ASCIIString, Any})
    out = Array(CatalogEntry, length(catalog["objid"]))

    for i=1:length(catalog["objid"])
        worldcoords = [catalog["ra"][i], catalog["dec"][i]]
        frac_dev = catalog["frac_dev"][i]

        # Fill star and galaxy flux
        star_fluxes = zeros(5)
        gal_fluxes = zeros(5)
        for (j, band) in enumerate(['u', 'g', 'r', 'i', 'z'])

            # Make negative fluxes positive.
            # TODO: How can there be negative fluxes?
            psfflux = max(catalog["psfflux_$band"][i], 1e-6)
            devflux = max(catalog["devflux_$band"][i], 1e-6)
            expflux = max(catalog["expflux_$band"][i], 1e-6)

            # galaxy flux is a weighted sum of the two components.
            star_fluxes[j] = psfflux
            gal_fluxes[j] = frac_dev * devflux + (1.0 - frac_dev) * expflux
        end

        # For shape parameters, we use the dominant component (dev or exp)
        usedev = frac_dev > 0.5
        fits_ab = usedev? catalog["ab_dev"][i] : catalog["ab_exp"][i]
        fits_phi = usedev? catalog["phi_dev"][i] : catalog["phi_exp"][i]
        fits_theta = usedev? catalog["theta_dev"][i] : catalog["theta_exp"][i]

        # use tractor convention of defining phi as -1 * the phi catalog
        fits_phi *= -1.0

        # effective radius
        re_arcsec = max(fits_theta, 1. / 30)
        re_pixel = re_arcsec / 0.396

        phi90 = 90 - fits_phi
        phi90 -= floor(phi90 / 180) * 180
        phi90 *= (pi / 180)

        entry = CatalogEntry(worldcoords, catalog["is_star"][i], star_fluxes,
                             gal_fluxes, frac_dev, fits_ab, phi90, re_pixel,
                             catalog["objid"][i], Int(catalog["thing_id"][i]))
        out[i] = entry
    end

    return out
end

"""
read_photoobj_celeste(fname)

Read a SDSS \"photoobj\" FITS catalog into a Vector{CatalogEntry}.
"""
function read_photoobj_celeste(fname)
    catalog = SDSSIO.read_photoobj(fname)
    return Vector{CatalogEntry}(catalog)
end

#
# The fname in the old `load_raw_field`:
#
#     b_letter = band_letters[b]
#     fname = "$field_dir/frame-$b_letter-$run_num-$camcol_num-$field_num.fits"
#


"""
Load a stamp catalog.
"""
function load_stamp_catalog(cat_dir, stamp_id, blob; match_blob=false)
    df = SDSS.load_stamp_catalog_df(cat_dir, stamp_id, blob,
                                    match_blob=match_blob)
    df[:objid] = [ string(s) for s=1:size(df)[1] ]
    convert_catalog_to_celeste(df, blob, match_blob=match_blob)
end


"""
Convert a dataframe catalog (e.g. as returned by
SDSS.load_catalog_df) to an array of Celeste CatalogEntry
objects.

Args:
  - df: The dataframe output of SDSS.load_catalog_df
  - blob: The blob that the catalog corresponds to
  - match_blob: If false, changes the direction of phi to match tractor,
                not Celeste.
"""
function convert_catalog_to_celeste(
  df::DataFrames.DataFrame, blob::Array{Image, 1}; match_blob=false)
    function row_to_ce(row)
        x_y = [row[1, :ra], row[1, :dec]]
        star_fluxes = zeros(5)
        gal_fluxes = zeros(5)
        fracs_dev = [row[1, :frac_dev], 1 - row[1, :frac_dev]]
        for b in 1:length(band_letters)
            bl = band_letters[b]
            psf_col = symbol("psfflux_$bl")

            # TODO: How can there be negative fluxes?
            star_fluxes[b] = max(row[1, psf_col], 1e-6)

            dev_col = symbol("devflux_$bl")
            exp_col = symbol("expflux_$bl")
            gal_fluxes[b] += fracs_dev[1] * max(row[1, dev_col], 1e-6) +
                             fracs_dev[2] * max(row[1, exp_col], 1e-6)
        end

        fits_ab = fracs_dev[1] > .5 ? row[1, :ab_dev] : row[1, :ab_exp]
        fits_phi = fracs_dev[1] > .5 ? row[1, :phi_dev] : row[1, :phi_exp]
        fits_theta = fracs_dev[1] > .5 ? row[1, :theta_dev] : row[1, :theta_exp]

        # tractor defines phi as -1 * the phi catalog for some reason.
        if !match_blob
            fits_phi *= -1.
        end

        re_arcsec = max(fits_theta, 1. / 30)  # re = effective radius
        re_pixel = re_arcsec / 0.396

        phi90 = 90 - fits_phi
        phi90 -= floor(phi90 / 180) * 180
        phi90 *= (pi / 180)

        CatalogEntry(x_y, row[1, :is_star], star_fluxes,
            gal_fluxes, row[1, :frac_dev], fits_ab, phi90, re_pixel,
            row[1, :objid], 0)
    end

    CatalogEntry[row_to_ce(df[i, :]) for i in 1:size(df, 1)]
end


"""
Load a stamp into a Celeste blob.
"""
function load_stamp_blob(stamp_dir, stamp_id)
    function fetch_image(b)
        band_letter = band_letters[b]
        filename = "$stamp_dir/stamp-$band_letter-$stamp_id.fits"

        fits = FITSIO.FITS(filename)
        hdr = FITSIO.read_header(fits[1])
        original_pixels = read(fits[1])
        dn = original_pixels / hdr["CALIB"] + hdr["SKY"]
        nelec_f32 = round(dn * hdr["GAIN"])
        nelec = convert(Array{Float64}, nelec_f32)

        header_str = FITSIO.read_header(fits[1], ASCIIString)
        wcs = WCS.from_header(header_str)[1]
        close(fits)

        alphaBar = [hdr["PSF_P0"]; hdr["PSF_P1"]; hdr["PSF_P2"]]
        xiBar = [
            [hdr["PSF_P3"]  hdr["PSF_P4"]];
            [hdr["PSF_P5"]  hdr["PSF_P6"]];
            [hdr["PSF_P7"]  hdr["PSF_P8"]]]'

        tauBar = Array(Float64, 2, 2, 3)
        tauBar[:,:,1] = [[hdr["PSF_P9"] hdr["PSF_P11"]];
                         [hdr["PSF_P11"] hdr["PSF_P10"]]]
        tauBar[:,:,2] = [[hdr["PSF_P12"] hdr["PSF_P14"]];
                         [hdr["PSF_P14"] hdr["PSF_P13"]]]
        tauBar[:,:,3] = [[hdr["PSF_P15"] hdr["PSF_P17"]];
                         [hdr["PSF_P17"] hdr["PSF_P16"]]]

        psf = [PsfComponent(alphaBar[k], xiBar[:, k],
                            tauBar[:, :, k]) for k in 1:3]

        H, W = size(original_pixels)
        iota = hdr["GAIN"] / hdr["CALIB"]
        epsilon = hdr["SKY"] * hdr["CALIB"]

        run_num = round(Int, hdr["RUN"])
        camcol_num = round(Int, hdr["CAMCOL"])
        field_num = round(Int, hdr["FIELD"])

        Image(H, W, nelec, b, wcs, epsilon, iota, psf,
              run_num, camcol_num, field_num)
    end

    blob = map(fetch_image, 1:5)
end


"""
read_sdss_field(run, camcol, field, frame_dir; ...)

Read a SDSS run/camcol/field into an array of Images. `frame_dir` is the
directory in which to find SDSS \"frame\" files. This function accepts
optional keyword arguments `fpm_dir`, `psfield_dir` and `photofield_dir`
giving the directories of fpM, psField and photoField files. The defaults
for these arguments is `frame_dir`.
"""
function read_sdss_field(run::Integer, camcol::Integer, field::Integer,
                         frame_dir::ByteString;
                         fpm_dir::ByteString=frame_dir,
                         psfield_dir::ByteString=frame_dir,
                         photofield_dir::ByteString=frame_dir)

    # read gain for each band
    photofield_name = @sprintf("%s/photoField-%06d-%d.fits",
                               photofield_dir, run, camcol)
    gains = SDSSIO.read_field_gains(photofield_name, field)

    # open FITS file containing PSF for each band
    psf_name = @sprintf("%s/psField-%06d-%d-%04d.fit",
                        psfield_dir, run, camcol, field)
    psffile = FITSIO.FITS(psf_name)

    result = Array(Image, 5)

    for (bandnum, band) in enumerate(['u', 'g', 'r', 'i', 'z'])

        # load image data
        frame_name = @sprintf("%s/frame-%s-%06d-%d-%04d.fits",
                              frame_dir, band, run, camcol, field)
        data, calibration, sky, wcs = SDSSIO.read_frame(frame_name)

        # scale data to raw electron counts
        SDSSIO.decalibrate!(data, sky, calibration, gains[band])

        # read mask
        mask_name = @sprintf("%s/fpM-%06d-%s%d-%04d.fit",
                             fpm_dir, run, band, camcol, field)
        mask_xranges, mask_yranges = SDSSIO.read_mask(mask_name)

        # apply mask
        for i=1:length(mask_xranges)
            data[mask_xranges[i], mask_yranges[i]] = NaN
        end

        H, W = size(data)

        # read the psf
        sdsspsf = SDSSIO.read_psf(psffile, band)

        # evalute the psf in the center of the image and then fit it.
        psfstamp = sdsspsf(H / 2., W / 2.)
        psf = PSF.fit_raw_psf_for_celeste(psfstamp)[1]

        # For now, use the median noise and sky.  Here,
        # epsilon * iota needs to be in units comparable to nelec
        # electron counts.
        # Note that each are actuall pretty variable.
        iota = Float64(gains[band] / median(calibration))
        epsilon = Float64(median(sky) * median(calibration))
        iota_vec = convert(Vector{Float64}, gains[band] ./ calibration)
        epsilon_mat = convert(Array{Float64, 2}, sky .* calibration)

        # Set it to use a constant background but include the non-constant data.
        result[bandnum] = Image(H, W, data, bandnum, wcs, epsilon, iota, psf,
                                run, camcol, field, false, epsilon_mat,
                                iota_vec, sdsspsf)
    end

    return result
end


"""
Crop an image in place to a (2 * width) x (2 * width) - pixel square centered
at the world coordinates wcs_center.
Args:
  - blob: The field to crop
  - width: The width in pixels of each quadrant
  - wcs_center: A location in world coordinates (e.g. the location of a
                celestial body)

Returns:
  - A tiled blob with a single tile in each image centered at wcs_center.
    This can be used to investigate a certain celestial object in a single
    tiled blob, for example.
"""
function crop_blob_to_location(
  blob::Array{Image, 1},
  width::Union{Float64, Int},
  wcs_center::Vector{Float64})
    @assert length(wcs_center) == 2
    @assert width > 0

    tiled_blob = Array(TiledImage, length(blob))
    for b=1:length(blob)
        # Get the pixels that are near enough to the wcs_center.
        pix_center = WCS.world_to_pix(blob[b].wcs, wcs_center)
        h_min = max(floor(Int, pix_center[1] - width), 1)
        h_max = min(ceil(Int, pix_center[1] + width), blob[b].H)
        sub_rows_h = h_min:h_max

        w_min = max(floor(Int, (pix_center[2] - width)), 1)
        w_max = min(ceil(Int, pix_center[2] + width), blob[b].W)
        sub_rows_w = w_min:w_max
        tiled_blob[b] = fill(ImageTile(blob[b], sub_rows_h, sub_rows_w), 1, 1)
    end
    tiled_blob
end


#######################################
# Tiling functions

"""
Convert an image to an array of tiles of a given width.

Args:
  - img: An image to be broken into tiles
  - tile_width: The size in pixels of each tile

Returns:
  An array of tiles containing the image.
"""
function break_image_into_tiles(img::Image, tile_width::Int)
  WW = ceil(Int, img.W / tile_width)
  HH = ceil(Int, img.H / tile_width)
  ImageTile[ ImageTile(hh, ww, img, tile_width) for hh=1:HH, ww=1:WW ]
end


"""
Break a blob into tiles.
"""
function break_blob_into_tiles(blob::Blob, tile_width::Int)
  [ break_image_into_tiles(img, tile_width) for img in blob ]
end


#######################################
# Functions for matching sources to tiles.

# A pixel circle maps locally to a world ellipse.  Return the major
# axis of that ellipse.
function pixel_radius_to_world(pix_radius::Float64,
                               wcs_jacobian::Matrix{Float64})
  pix_radius / minimum(abs(eigvals(wcs_jacobian)));
end

import WCS.world_to_pix
world_to_pix{T <: Number}(patch::SkyPatch, world_loc::Vector{T}) =
    world_to_pix(patch.wcs_jacobian, patch.center, patch.pixel_center,
                 world_loc)


"""
Return a vector of (h, w) indices of tiles that contain this source.
"""
function find_source_tiles(s::Int, b::Int, mp::ModelParams)
  [ ind2sub(size(mp.tile_sources[b]), ind) for ind in
    find([ s in sources for sources in mp.tile_sources[b]]) ]
end

"""
Combine the tiles associated with a single source into an image.

Args:
  s: The source index
  b: The band
  mp: The ModelParams object
  tiled_blob: The original tiled blob
  predicted: If true, render the object based on the values in ModelParams.
             Otherwise, show the image from tiled_blob.

Returns:
  A matrix of pixel values for the particular object using only tiles in
  which it is found according to the ModelParams tile_sources field.  Pixels
  from tiles that do not have this source will be marked as 0.0.
"""
function stitch_object_tiles(
    s::Int, b::Int, mp::ModelParams{Float64}, tiled_blob::TiledBlob;
    predicted::Bool=false)

  H, W = size(tiled_blob[b])
  has_s = Bool[ s in mp.tile_sources[b][h, w] for h=1:H, w=1:W ];
  tiles_s = tiled_blob[b][has_s];
  tile_sources_s = mp.tile_sources[b][has_s];
  h_range = Int[typemax(Int), typemin(Int)]
  w_range = Int[typemax(Int), typemin(Int)]
  print("Stitching...")
  for tile in tiles_s
    print(".")
    h_range[1] = min(minimum(tile.h_range), h_range[1])
    h_range[2] = max(maximum(tile.h_range), h_range[2])
    w_range[1] = min(minimum(tile.w_range), w_range[1])
    w_range[2] = max(maximum(tile.w_range), w_range[2])
  end

  image_s = fill(0.0, diff(h_range)[1] + 1, diff(w_range)[1] + 1);
  for tile_ind in 1:length(tiles_s)
    tile = tiles_s[tile_ind]
    tile_sources = tile_sources_s[tile_ind]
    image_s[tile.h_range - h_range[1] + 1, tile.w_range - w_range[1] + 1] =
      predicted ?
      ElboDeriv.tile_predicted_image(tile, mp, Int[ s ], include_epsilon=false):
      tile.pixels
  end
  println("Done.")
  image_s, h_range, w_range
end


end  # module
