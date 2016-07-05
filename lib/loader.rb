require 'sequel'
require 'logger'

DB = Sequel::Model.db = Sequel.connect(ENV['DATABASE_URL'])

Sequel::Model.raise_on_save_failure = true
  
module Conjur
  module Policy
    module Types
      module CreateRole
        def create_role!
          ::Role.create id: roleid
        end
        
        def role
          ::Role[roleid]
        end
      end

      module CreateResource
        def create_resource!
          ::Resource.create(id: resourceid, owner: (::Role[owner.roleid] or raise IndexError, owner.roleid)).tap do |resource|
            Hash(annotations).each do |name, value|
              resource.add_annotation name: name, value: value
            end
          end
        end
        
        def resource
          ::Resource[resourceid]
        end
      end
      
      class Role
        include CreateRole
        
        def create!
          create_role!
        end
      end

      class Resource
        include CreateResource
        
        def create!
          create_resource!
        end
      end
      
      class Variable
        include CreateResource
        
        def create!
          create_resource!
        end
      end
      
      class Record
        include CreateRole
        include CreateResource
        
        def create!
          create_role!
          create_resource!
        end
      end
      
      class Layer < Record
        def create!
          super
          
          observe, use, admin = %w(observe use_host admin_host).map do |role_name|
            ::Role.create id: [ account, '@', [ role_kind, id, role_name ].join('/') ].join(":")
          end
          observe.grant_to use
          use.grant_to admin
        end
        
        def automatic_role role_name
          roleid = [ account, '@', [ role_kind, id, role_name ].join('/')].join(":")
          ::Role[roleid] or raise IndexError, roleid
        end
      end

      class Host < Record
      end

      class Group < Record
        def create!
          super
          
          if gidnumber
            role.update gidnumber: self.gidnumber
          end
        end
      end
      
      class User < Record
        def create!
          super
          
          if uidnumber
            role.update uidnumber: self.uidnumber
          end
          
          Array(public_keys).each do |public_key|
            key_name = PublicKey.key_name public_key

            resourceid = [ self.account, "variable", [ "public_keys", self.id, key_name ].join('/') ].join(":")
            ::Resource.create(id: resourceid, owner: (::Role[owner.roleid] or raise IndexError, owner.roleid)).tap do |resource|
              resource.add_annotation name: "possum/variable/kind", value: "SSH public key"
              ::Secret.create resource_id: resource.id, value: public_key
              %w(read execute).each do |privilege|
                resource.permit privilege, self.role
              end
            end
          end
        end
      end

      class HostFactory
        include CreateResource
        
        def create!
          create_resource!
          
          account, _, id = resourceid.split(":", 3)
          deputy = ::Role.create id: [ account, 'deputy', id ].join(":")
          layers.each do |layer|
            layer = (::Role[layer.roleid] or raise IndexError, layer.roleid)
            layer.grant_to deputy
          end
        end
      end
      
      class Grant
        def create!
          Array(roles).each do |r|
            Array(members).each do |m|
              role = ::Role[r.roleid] or raise IndexError, r.roleid
              member = ::Role[m.role.roleid] or raise IndexError, m.role.roleid
              role.grant_to member, admin_option: m.admin
              
              if r.is_a?(Layer) && m.role.is_a?(Host)
                resource = ::Resource[m.role.resourceid] or raise IndexError, m.role.resourceid
                
                resource.permit 'read', r.automatic_role('observe')
                resource.permit 'execute', r.automatic_role('use_host')
                resource.permit 'update', r.automatic_role('admin_host')
              end
            end
          end
        end
      end

      class Permit
        def create!
          Array(resources).each do |r|
            Array(privileges).each do |p|
              Array(roles).each do |m|
                resource = ::Resource[r.resourceid] or raise IndexError, r.resourceid
                member = ::Role[m.role.roleid] or raise IndexError, m.role.roleid
                resource.permit p, member
              end
            end
          end
        end
      end
      
      class Policy
        def create!
          self.role.create!
          self.resource.create!
          
          Array(body).map(&:create!)
        end
      end
    end
  end
end
  
class Loader
  class << self
    def enable_logging
      DB.loggers << Logger.new($stdout)
    end
    
    def load filename, account
      records = Conjur::Policy::YAML::Loader.load_file(filename)
      records = Conjur::Policy::Resolver.resolve records, account, "#{account}:user:admin"

      DB[:roles].delete

      ::Role.create id: "#{account}:user:admin"
      
      records.map(&:create!)
    end
  end
end
