# This file is the thing you have to config to match your application

class ImportProductSettings

    #Take a look at the data you need to be importing, and then change this hash accordingly
    #The first column is 0, etc etc.
    #This is accessed in the import method using COLUMN_MAPPINGS['field'] for niceness and readability
    #TODO this could probably be marked up in YML

    # Original columns
    # COLUMN_MAPPINGS = {
    #   'SKU' => 0,
    #   'Name' => 1,
    #   'Master Price' => 2,
    #   'Cost Price' => 3,
    #   'Weight' => 4,
    #   'Height' => 5,
    #   'Width' => 6,
    #   'Depth' => 7,
    #   'Image Main' => 8,
    #   'Image 2' => 9,
    #   'Image 3' => 10,
    #   'Image 4' => 11,
    #   'Description' => 12,
    #   'Category' => 13
    # }
    
    # Globalener csv columns
    COLUMN_MAPPINGS = {
      'libelle' => 0,
      'rien1' => 1,
      'description_prod' => 2,
      'rien2' => 3,
      'prixprodht' => 4,
      'idclassif' => 5,
      'classif' => 6,
      'idarticle' => 7,
      'rien3' => 8,
      'idfournisseur' => 9,
      'fournisseur' => 10,
      'reffournisseur' => 11,
      'codebarre' => 12,
      'idmarque' => 13,
      'idmarqueremise' => 14,
      'refremplacement' => 15
    }

    #Where are you keeping your master images?
    #This path is the path that the import code will search for filenames matching those in your CSV file
    #As each product is saved, Spree (Well, paperclip) grabs it, transforms it into a range of sizes and
    #saves the resulting files somewhere else - this is just a repository of originals.
    PRODUCT_IMAGE_PATH = "#{Rails.root}/lib/etc/product-data/product-images/"
    
    #From experience, CSV files from clients tend to have a few 'header' rows - count them up if you have them,
    #and enter this number in here - the import script will skip these rows.
    INITIAL_ROWS_TO_SKIP = 1

    #I would just leave this as is - Logging is useful for a batch job like this - so
    # useful in fact, that I have put it in a separate log file.
    LOGFILE = File.join(Rails.root, '/log/', "import_products_#{Rails.env}.log")
    
    #Set this to true if you want to destroy your existing products after you have finished importing products
    DESTROY_ORIGINAL_PRODUCTS_AFTER_IMPORT = false
    
    #Set default Shipping Category (this will be created if it doesn't already exist
    DEFAULT_SHIPPING_CATEGORY = "France"
    
    #Set default Tax Category (this will be created if it doesn't exist)
    #However, you may want to setup your tax setup before using this extension
    DEFAULT_TAX_CATEGORY = ""
    
    #Set default HTML decoding settings
    #If set to true, all names and descriptions will convert
    #&amp; to &, &gt; to >, etc.
    HTML_DECODE_NAMES = false
    HTML_DECODE_DESCRIPTIONS = true
end
