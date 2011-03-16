# This model is the master routine for uploading products
# Requires Paperclip and FasterCSV to upload the CSV file and read it nicely.

# Author:: Josh McArthur
# License:: MIT

class ProductImport < ActiveRecord::Base
  has_attached_file :data_file, :path => ":rails_root/lib/etc/product_data/data-files/:basename.:extension"
  validates_attachment_presence :data_file
  
  require 'fastercsv'
  require 'pp'
  require 'htmlentities'
  
  ## Data Importing:
  # Supplier, room and category are all taxonomies to be found (or created) and associated
  # Model maps to product name, description, brochure text and bullets 1 - 8 are combined to form description
  # List Price maps to Master Price, Current MAP to Cost Price, Net 30 Cost unused
  # Width, height, Depth all map directly to object
  # Image main is created independtly, then each other image also created and associated with the product
  # Meta keywords and description are created on the product model
  
  def import_data
    begin
      #Get products *before* import - 
      @products_before_import = Product.all

      #Setup HTML decoder
      coder = HTMLEntities.new

      columns = ImportProductSettings::COLUMN_MAPPINGS
      log("Import - Columns setting: #{columns.inspect}")
      
      rows = FasterCSV.read(self.data_file.path, {:col_sep => '|'})
      log("Importing products for #{self.data_file_file_name} began at #{Time.now}")
      nameless_product_count = 0
      
      rows[ImportProductSettings::INITIAL_ROWS_TO_SKIP..-1].each do |row|
        
        log("Import - Current row: #{row[columns['libelle']]}")
        
        #Create the product skeleton - should be valid
        product_obj = Product.new()
      
        product_obj.name = row[columns['libelle']]
        product_obj.sku = row[columns['codebarre']] || product_obj.name.gsub(' ', '_')
        product_obj.price = row[columns['prixprodht']] || 0.0
        product_obj.description = row[columns['description_prod']]
        
        #Assign a default shipping category
        product_obj.shipping_category = ShippingCategory.find_or_create_by_name(ImportProductSettings::DEFAULT_SHIPPING_CATEGORY)
        product_obj.tax_category = TaxCategory.find_or_create_by_name(ImportProductSettings::DEFAULT_TAX_CATEGORY)

        unless product_obj.valid?
          log("A product could not be imported - here is the information we have:\n #{ pp product_obj.attributes}", :error)
          next
        end
      
        #Save the object before creating asssociated objects
        product_obj.save!
      
        idclassif_prop = Property.find_or_create_by_name_and_presentation("idclassif", "idclassif")
        ProductProperty.create :property => idclassif_prop, :product => product_obj, :value => row[columns['idclassif']]
        
        brand_prop = Property.find_or_create_by_name_and_presentation("idmarque", "idmarque")
        ProductProperty.create :property => brand_prop, :product => product_obj, :value => row[columns['idmarque']]
        
        fournisseur_prop = Property.find_or_create_by_name_and_presentation("idfournisseur", "idfournisseur")
        ProductProperty.create :property => fournisseur_prop, :product => product_obj, :value => row[columns['idfournisseur']]
        
        #Now we have all but images and taxons loaded
        associate_taxon('classif', row[columns['classif']], product_obj)
        associate_taxon('idarticle', row[columns['idarticle']], product_obj)
        associate_taxon('fournisseur', row[columns['fournisseur']], product_obj)
        associate_taxon('reffournisseur', row[columns['reffournisseur']], product_obj)
        associate_taxon('idmarqueremise', row[columns['idmarqueremise']], product_obj)
        associate_taxon('refremplacement', row[columns['refremplacement']], product_obj)
        
        #Save master variant, for some reason saving product with price set above
        #doesn't create the master variant
        log("Master Variant saved for #{product_obj.sku}") if product_obj.master.save!
        
        image_file = File.join(row[columns['idfournisseur']], "#{row[columns['reffournisseur']]}.jpg")
        find_and_attach_image(image_file, product_obj)

        #Return a success message
        log("[#{product_obj.sku}] #{product_obj.name}($#{product_obj.master.price}) successfully imported.\n") if product_obj.save

      end
      
      if ImportProductSettings::DESTROY_ORIGINAL_PRODUCTS_AFTER_IMPORT
        @products_before_import.each { |p| p.destroy }
      end
    
      log("Importing products for #{self.data_file_file_name} completed at #{DateTime.now}")
      
    rescue Exception => exp
      log("An error occurred during import, please check file and try again. (#{exp.message})\n#{exp.backtrace.join('\n')}", :error)
      return [:error, "The file data could not be imported. Please check that the spreadsheet is a CSV file, and is correctly formatted."]
    end
    
    #All done!
    return [:notice, "Product data was successfully imported."]
  end
  
  
  private 
  
  ### MISC HELPERS ####
  
  #Log a message to a file - logs in standard Rails format to logfile set up in the import_products initializer
  #and console.
  #Message is string, severity symbol - either :info, :warn or :error
  
  def log(message, severity = :info)   
    @rake_log ||= ActiveSupport::BufferedLogger.new(ImportProductSettings::LOGFILE)
    message = "[#{Time.now.to_s(:db)}] [#{severity.to_s.capitalize}] #{message}\n"
    @rake_log.send severity, message
    puts message
  end

  
  ### IMAGE HELPERS ###
  
  ## find_and_attach_image
  #   The theory behind this method is:
  #     - We know where an 'image dump' of high-res images is - could be remote folder, or local
  #     - We know that the provided filename SHOULD be in this folder
  def find_and_attach_image(filename, product)
    #Does the file exist? Can we read it?
    return if filename.blank?
    filename = ImportProductSettings::PRODUCT_IMAGE_PATH + filename
    log("filename::::: #{filename}")
    unless File.exists?(filename) && File.readable?(filename)
      log("Image #{filename} was not found on the server, so this image was not imported.", :warn)
      return nil
    end
    
    #An image has an attachment (duh) and some object which 'views' it
    product_image = Image.new({:attachment => File.open(filename, 'rb'), 
                              :viewable => product,
                              :position => product.images.length
                              }) 
    
    product.images << product_image if product_image.save
  end

  
  
  ### TAXON HELPERS ###  
  def associate_taxon(taxonomy_name, taxon_name, product)
    master_taxon = Taxonomy.find_by_name(taxonomy_name)
    
    #Find all existing taxons and assign them to the product
    existing_taxons = Taxon.find_all_by_name(taxon_name)
    if existing_taxons and !existing_taxons.empty?
      existing_taxons.each do |taxon|
        product.taxons << taxon
      end
    else
      #Create any taxons that don't exist
      master_taxon = Taxonomy.find_by_name(taxonomy_name)
      if master_taxon.nil?
        master_taxon = Taxonomy.create(:name => taxonomy_name)
        log("Could not find Category taxonomy, so it was created.", :warn)
      end

      taxon = Taxon.find_or_create_by_name_and_parent_id_and_taxonomy_id(
        taxon_name,
        master_taxon.root.id,
        master_taxon.id
      )

      product.taxons << taxon if taxon.save
    end

  end
  ### END TAXON HELPERS ###
end
