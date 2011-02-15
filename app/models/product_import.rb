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
      
      rows = FasterCSV.read(self.data_file.path)
      log("Importing products for #{self.data_file_file_name} began at #{Time.now}")
      nameless_product_count = 0
      
      rows[ImportProductSettings::INITIAL_ROWS_TO_SKIP..-1].each do |row|
        
        log("Import - Current row: #{row.inspect}")
        
        if product_obj = Product.find(:first, :include => [:product_properties, :properties], :conditions => ['properties.name LIKE ? && product_properties.value LIKE ?', "XmlImportId", row[columns['Id']]])
          
          create_variant(product_obj, row, columns)
          log("Variant saved for #{v.sku}")
          
        else
          #Create the product skeleton - should be valid
          product_obj = Product.new()
        
          #Easy ones first
          if row[columns['Name']].blank?
            log("Product with no name: #{row[columns['Description']]}")
            product_obj.name = "No-name product #{nameless_product_count}"
            nameless_product_count += 1
          else
            #Decode HTML for names and/or descriptions if necessary
            if ImportProductSettings::HTML_DECODE_NAMES
              product_obj.name = coder.decode(row[columns['Name']])
            else
              product_obj.name = row[columns['Name']]
            end
          end
          #product_obj.sku = row[columns['SKU']] || product_obj.name.gsub(' ', '_')
          product_obj.price = row[columns['Master Price']] || 0.0
          #product_obj.cost_price = row[columns['Cost Price']]
          product_obj.available_on = DateTime.now - 1.day #Yesterday to make SURE it shows up
          product_obj.weight = columns['Weight'] ? row[columns['Weight']] : 0.0
          product_obj.height = columns['Height'] ? row[columns['Height']] : 0.0
          product_obj.depth = columns['Depth'] ? row[columns['Depth']] : 0.0
          product_obj.width = columns['Width'] ? row[columns['Width']] : 0.0
          #Decode HTML for descriptions if needed
          if ImportProductSettings::HTML_DECODE_DESCRIPTIONS
            product_obj.description = coder.decode(row[columns['Description']])
          else
            product_obj.description = row[columns['Description']]
          end
        
        
          #Assign a default shipping category
          product_obj.shipping_category = ShippingCategory.find_or_create_by_name(ImportProductSettings::DEFAULT_SHIPPING_CATEGORY)
          product_obj.tax_category = TaxCategory.find_or_create_by_name(ImportProductSettings::DEFAULT_TAX_CATEGORY)

          unless product_obj.valid?
            log("A product could not be imported - here is the information we have:\n #{ pp product_obj.attributes}", :error)
            next
          end
        
          #Save the object before creating asssociated objects
          product_obj.save!
        
          xml_import_id_prop = Property.find_or_create_by_name_and_presentation("XmlImportId", "XmlImportId")
          ProductProperty.create :property => xml_import_id_prop, :product => product_obj, :value => row[columns['Id']]
        
          unless product_obj.master
            log("[ERROR] No variant set for: #{product_obj.name}")
          end

          #Now we have all but images and taxons loaded
          associate_taxon('Category', row[columns['Category']], product_obj)
          associate_taxon('Gender', row[columns['Gender']], product_obj)

          #Just images 
          #find_and_attach_image(row[columns['Image Main']], product_obj)
          #find_and_attach_image(row[columns['Image 2']], product_obj)
          #find_and_attach_image(row[columns['Image 3']], product_obj)
          #find_and_attach_image(row[columns['Image 4']], product_obj)

          #Save master variant, for some reason saving product with price set above
          #doesn't create the master variant
          log("Master Variant saved for #{product_obj.sku}") if product_obj.master.save!
          
          create_variant(product_obj, row, columns)
          
          log("Variant saved for #{v.sku}") 

          #Return a success message
          log("[#{product_obj.sku}] #{product_obj.name}($#{product_obj.master.price}) successfully imported.\n") if product_obj.save
        end
        
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
  
  ### VARIANT HELPERS ###  
  def create_variant(product_obj, row, columns)
    v = Variant.create :product => product_obj, :sku => row[columns['SKU']], :price => row[columns['Master Price']]
    
    [
      ["Brand", "Marque"],
      ["Color", "Couleur"],
      ["Size", "Taille"],
      ["Age", "Age"],
    ]. each do |name, presentation|
      
      log("Import - Variant option: #{name} - value: #{row[columns[name]]}")
      
      if value = row[columns[name]]
        unless option_type = OptionType.first(:conditions => ["name LIKE ? AND presentation LIKE ?", name, presentation])
          option_type = OptionType.create! :name => name, :presentation => presentation
        end
        if option_value = OptionValue.first(:conditions => ["name LIKE ? AND presentation LIKE ? AND option_type_id = ?", name, presentation, option_type.id])
          option_value = OptionValue.create! :name => value, :presentation => value, :option_type => option_type
        end
        v.option_values << option_value
      end
      
    end
    
    v.save!
    product_obj.save!
  end
end