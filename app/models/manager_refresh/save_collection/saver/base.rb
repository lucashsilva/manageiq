module ManagerRefresh::SaveCollection
  module Saver
    class Base
      include Vmdb::Logging
      include ManagerRefresh::SaveCollection::Saver::SqlHelper

      attr_reader :inventory_collection, :association

      def initialize(inventory_collection)
        @inventory_collection = inventory_collection

        # Private attrs
        @primary_key            = inventory_collection.model_class.primary_key
        @arel_primary_key       = inventory_collection.model_class.arel_attribute(primary_key)
        @unique_index_keys      = inventory_collection.manager_ref_to_cols.map(&:to_sym)
        @unique_index_keys_to_s = inventory_collection.manager_ref_to_cols.map(&:to_s)
        @select_keys            = [@primary_key] + @unique_index_keys_to_s
        @unique_db_primary_keys = Set.new
        @unique_db_indexes      = Set.new

        # TODO(lsmola) do I need to reload every time? Also it should be enough to clear the associations.
        inventory_collection.parent.reload if inventory_collection.parent
        @association = inventory_collection.db_collection_for_comparison

        # Right now ApplicationRecordIterator in association is used for targeted refresh. Given the small amount of
        # records flowing through there, we probably don't need to optimize that association to fetch a pure SQL.
        @pure_sql_records_fetching = !inventory_collection.use_ar_object? && !@association.kind_of?(ManagerRefresh::ApplicationRecordIterator)

        @batch_size_for_persisting = inventory_collection.batch_size_pure_sql

        @batch_size          = @pure_sql_records_fetching ? @batch_size_for_persisting : inventory_collection.batch_size
        @record_key_method   = @pure_sql_records_fetching ? :pure_sql_record_key : :ar_record_key
        @select_keys_indexes = @select_keys.each_with_object({}).with_index { |(key, obj), index| obj[key.to_s] = index }
      end

      def save_inventory_collection!
        # If we have a targeted InventoryCollection that wouldn't do anything, quickly skip it
        return if inventory_collection.noop?
        # If we want to use delete_complement strategy using :all_manager_uuids attribute, we are skipping any other
        # job. We want to do 1 :delete_complement job at 1 time, to keep to memory down.
        return delete_complement if inventory_collection.all_manager_uuids.present?

        save!(association)
      end

      private

      attr_reader :unique_index_keys, :unique_index_keys_to_s, :select_keys, :unique_db_primary_keys, :unique_db_indexes,
                  :primary_key, :arel_primary_key, :record_key_method, :pure_sql_records_fetching, :select_keys_indexes,
                  :batch_size, :batch_size_for_persisting

      def save!(association)
        attributes_index        = {}
        inventory_objects_index = {}
        inventory_collection.each do |inventory_object|
          attributes = inventory_object.attributes(inventory_collection)
          index      = inventory_object.manager_uuid

          attributes_index[index]        = attributes
          inventory_objects_index[index] = inventory_object
        end

        _log.info("*************** PROCESSING #{inventory_collection} of size #{inventory_collection.size} *************")
        # Records that are in the DB, we will be updating or deleting them.
        ActiveRecord::Base.transaction do
          association.find_each do |record|
            index = inventory_collection.object_index_with_keys(unique_index_keys, record)

            next unless assert_distinct_relation(record.id)
            next unless assert_unique_record(record, index)

            inventory_object = inventory_objects_index.delete(index)
            hash             = attributes_index.delete(index)

            if inventory_object.nil?
              # Record was found in the DB but not sent for saving, that means it doesn't exist anymore and we should
              # delete it from the DB.
              delete_record!(record) if inventory_collection.delete_allowed?
            else
              # Record was found in the DB and sent for saving, we will be updating the DB.
              update_record!(record, hash, inventory_object) if assert_referential_integrity(hash)
            end
          end
        end

        unless inventory_collection.custom_reconnect_block.nil?
          inventory_collection.custom_reconnect_block.call(inventory_collection, inventory_objects_index, attributes_index)
        end

        # Records that were not found in the DB but sent for saving, we will be creating these in the DB.
        if inventory_collection.create_allowed?
          ActiveRecord::Base.transaction do
            inventory_objects_index.each do |index, inventory_object|
              hash = attributes_index.delete(index)

              create_record!(hash, inventory_object) if assert_referential_integrity(hash)
            end
          end
        end
        _log.info("*************** PROCESSED #{inventory_collection}, "\
                  "created=#{inventory_collection.created_records.count}, "\
                  "updated=#{inventory_collection.updated_records.count}, "\
                  "deleted=#{inventory_collection.deleted_records.count} *************")
      rescue => e
        _log.error("Error when saving #{inventory_collection} with #{inventory_collection_details}. Message: #{e.message}")
        raise e
      end

      def inventory_collection_details
        "strategy: #{inventory_collection.strategy}, saver_strategy: #{inventory_collection.saver_strategy}, targeted: #{inventory_collection.targeted?}"
      end

      def record_key(record, key)
        record.public_send(key)
      end

      def delete_complement
        return unless inventory_collection.delete_allowed?

        all_manager_uuids_size = inventory_collection.all_manager_uuids.size

        _log.info("*************** PROCESSING :delete_complement of #{inventory_collection} of size "\
                  "#{all_manager_uuids_size} *************")
        deleted_counter = 0

        inventory_collection.db_collection_for_comparison_for_complement_of(
          inventory_collection.all_manager_uuids
        ).find_in_batches do |batch|
          ActiveRecord::Base.transaction do
            batch.each do |record|
              record.public_send(inventory_collection.delete_method)
              deleted_counter += 1
            end
          end
        end

        _log.info("*************** PROCESSED :delete_complement of #{inventory_collection} of size "\
                  "#{all_manager_uuids_size}, deleted=#{deleted_counter} *************")
      end

      def delete_record!(record)
        record.public_send(inventory_collection.delete_method)
        inventory_collection.store_deleted_records(record)
      end

      def assert_unique_record(_record, _index)
        # TODO(lsmola) can go away once we indexed our DB with unique indexes
        true
      end

      def assert_distinct_relation(primary_key_value)
        if unique_db_primary_keys.include?(primary_key_value) # Include on Set is O(1)
          # Change the InventoryCollection's :association or :arel parameter to return distinct results. The :through
          # relations can return the same record multiple times. We don't want to do SELECT DISTINCT by default, since
          # it can be very slow.
          if Rails.env.production?
            _log.warn("Please update :association or :arel for #{inventory_collection} to return a DISTINCT result. "\
                        " The duplicate value is being ignored.")
            return false
          else
            raise("Please update :association or :arel for #{inventory_collection} to return a DISTINCT result. ")
          end
        else
          unique_db_primary_keys << primary_key_value
        end
        true
      end

      def assert_referential_integrity(hash)
        inventory_collection.fixed_foreign_keys.each do |x|
          next unless hash[x].nil?
          subject = "#{hash} of #{inventory_collection} because of missing foreign key #{x} for "\
                    "#{inventory_collection.parent.class.name}:"\
                    "#{inventory_collection.parent.try(:id)}"
          if Rails.env.production?
            _log.warn("Referential integrity check violated, ignoring #{subject}")
            return false
          else
            raise("Referential integrity check violated for #{subject}")
          end
        end
        true
      end

      def time_now
        # A rails friendly time getting config from ActiveRecord::Base.default_timezone (can be :local or :utc)
        if ActiveRecord::Base.default_timezone == :utc
          Time.now.utc
        else
          Time.zone.now
        end
      end

      def supports_remote_data_timestamp?(all_attribute_keys)
        all_attribute_keys.include?(:remote_data_timestamp) # include? on Set is O(1)
      end

      def assign_attributes_for_update!(hash, update_time)
        hash[:updated_on]   = update_time if inventory_collection.supports_updated_on?
        hash[:updated_at]   = update_time if inventory_collection.supports_updated_at?
      end

      def assign_attributes_for_create!(hash, create_time)
        hash[:type]         = inventory_collection.model_class.name if inventory_collection.supports_sti? && hash[:type].nil?
        hash[:created_on]   = create_time if inventory_collection.supports_created_on?
        hash[:created_at]   = create_time if inventory_collection.supports_created_at?
        assign_attributes_for_update!(hash, create_time)
      end
    end
  end
end
