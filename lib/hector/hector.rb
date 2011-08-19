import 'me.prettyprint.hector.api.factory.HFactory'
import 'me.prettyprint.hector.api.mutation.Mutator'
import 'me.prettyprint.hector.api.Cluster'
import 'me.prettyprint.hector.api.query.Query'
import 'me.prettyprint.cassandra.service.CassandraHostConfigurator'
import 'me.prettyprint.cassandra.serializers.TypeInferringSerializer'

=begin rdoc
=end

class Hector
  include Helpers
  include DDL
  include Serialize

  class AccessError < StandardError #:nodoc:
  end

  TYPE_INFERRING = TypeInferringSerializer.get

  WRITE_DEFAULTS = {
    :k_serializer => :infer,
    :n_serializer => :infer,
    :v_serializer => :infer,
    :s_serializer => :infer
  }

  READ_DEFAULTS = {
    :k_serializer => :infer,
    :n_serializer => :bytes,
    :v_serializer => :bytes,
    :s_serializer => :bytes, 
    :count => java.lang.Integer::MAX_VALUE,
    :start => nil,
    :finish => nil,
    :reversed => false
  }

  attr_reader :keyspace, :cluster, :connection

  def self.cluster(cluster_name, server)
    HFactory.getOrCreateCluster(cluster_name, CassandraHostConfigurator.new(server))
  end

  # Create a new Hector instance and open the connection.
  def initialize(keyspace_name, server_or_cluster = "127.0.0.1:9160", options = {})
    cluster_name = options[:cluster_name] || "Hector"
    @cluster = server_or_cluster.kind_of?(String) ? self.class.cluster(cluster_name, server_or_cluster) : server_or_cluster
    self.keyspace = keyspace_name if keyspace_name
  end

  def keyspace=(keyspace_name)
    @keyspace = HFactory.createKeyspace(keyspace_name, @cluster)
  end

  def clear_column_family!(cf)
    # pp cf
  end

  def clear_keyspace!(keyspace_name)
    describe_keyspace(keyspace_name)[:cf_defs].each{|cf| clear_column_family!(cf)}
  end

  def disconnect
    HFactory.shutdownCluster(@cluster);
  end

  # note, how we're giving every column the same seralizer
  # here. TODO have more advanced options where we can specify
  # per-name column serialization
  def create_column(n, v, options = {})
    ks, ss, ns, vs = *seropts(options)
    if v.kind_of?(Hash)
      cols = v.collect {|name,value| create_column(name, value, options)}
      HFactory.createSuperColumn(n, cols, ss, ns, vs)
    else
      HFactory.createColumn(n, v, ns, vs)
    end
  end

  def put_row(column_family, key, hash, options = {})
    column_family, options = column_family.to_s, WRITE_DEFAULTS.merge(options)
    ks, _, _, _ = *seropts(options)
    mut = HFactory.createMutator(@keyspace, ks)
    hash.each do |k,v|
      mut.addInsertion(key, column_family, create_column(k, v, options))
    end
    mut.execute
  end

  def get_rows(column_family, pks, options = {})
    column_family, options = column_family.to_s, READ_DEFAULTS.merge(options)
    ks, ss, ns, vs = *seropts(options)
    query = returning HFactory.createMultigetSliceQuery(@keyspace, serializer(pks.first), ns, vs) do |q|
      q.setColumnFamily(column_family)
      q.setKeys(pks.to_java(:object))
      q.setRange(options[:start].to_java, options[:finish].to_java, options[:reversed], options[:count])
    end
    execute_query(query)
  end

  def get_columns(column_family, pk, columns, options = {}) 
    column_family, options = column_family.to_s, READ_DEFAULTS.merge(options)
    ks, _, ns, vs = *seropts(options)
    if columns.size < 2
      query = returning HFactory.createColumnQuery(@keyspace, ks, ns, vs) do |q|
        q.setColumnFamily(column_family)
        q.setKey(pk)
        q.setName(columns.first)
      end
      execute_query(query)
    else
    end
  end

  def get_range(column_family, start, finish, options = {})
    column_family, options = column_family.to_s, READ_DEFAULTS.merge(options)
    options = {:start => '', :finish => ''}.merge(options)
    ks, ss, ns, vs = *seropts(options)
    ks = ks.class == TypeInferringSerializer ? serializer(start) : ks # TODO
    query = returning HFactory.createRangeSlicesQuery(@keyspace, ks, ns, vs) do |q|
      q.setColumnFamily(column_family)
      q.setKeys(start.to_java, finish.to_java)
      q.setRange(options[:start].to_java, options[:finish].to_java, options[:reversed], options[:count])
    end
    execute_query(query)
  end

  def delete_columns(column_family, pk, columns, options = {})
    column_family, options = column_family.to_s, WRITE_DEFAULTS.merge(options)
    ks, _, ns, _ = *seropts(options)
    mut = returning HFactory.createMutator(@keyspace, ks) do |m|
      columns.map do |column|
        m.addDeletion pk, column_family, column, ns 
      end 
    end
    mut.execute
  end

  def delete_rows(column_family, pks, options = {})
    column_family, options = column_family.to_s, WRITE_DEFAULTS.merge(options)
    ks, _, ns, _ = *seropts(options)
    mut = returning HFactory.createMutator(@keyspace, ks) do |m|
      pks.map do |k|
        m.addDeletion k, column_family 
      end 
    end
    mut.execute
  end

  def execute_query(q)
    h_to_rb(q.execute)
  end

  # "Counts number of columns for pk in column family cf. The
  # method is not O(1). It takes all the columns from disk to
  # calculate the answer. The only benefit of the method is that
  # you do not need to pull all the columns over Thrift interface
  # to count them."
  def count_columns(column_family, pk, options = {})
    column_family, options = column_family.to_s, READ_DEFAULTS.merge(options)
    ks, ss, ns, vs = *seropts(options)
    
    query = returning HFactory.createCountQuery(@keyspace, ks, ns) do |q|
      q.setKey(pk)
      q.setRange(options[:start].to_java, options[:finish].to_java, options[:count])
      q.setColumnFamily(column_family)
    end
    execute_query(query)
  end

  def get_super_rows(column_family, pks, sc, options = {})
    column_family, options = column_family.to_s, READ_DEFAULTS.merge(options)
    _, ss, ns, vs = *seropts(options)
    query = returning HFactory.createMultigetSuperSliceQuery(@keyspace, serializer(pks.first), ss, ns, vs) do |q|
      q.setColumnFamily(column_family)
      q.setKeys(pks.to_java(:object))
      q.setColumnNames(sc.to_java(:object))
      q.setRange(options[:start].to_java, options[:finish].to_java, options[:reversed], options[:count])
    end
    execute_query(query)
  end

  def get_super_columns(column_family, pk, sc, c, options = {})
    column_family, options = column_family.to_s, READ_DEFAULTS.merge(options)
    ks, ss, ns, vs = *seropts(options)
    query = returning HFactory.createSubSliceQuery(@keyspace, ks, ss, ns, vs) do |q|
      q.setColumnFamily(column_family)
      q.setKey(pk)
      q.setSuperColumn(sc)
      q.setColumnNames(c.to_java(:object))
    end
    execute_query(query)
  end

  def delete_super_columns(column_family, columns, options = {})
    column_family, options = column_family.to_s, READ_DEFAULTS.merge(options)
    ks, ss, ns, vs = *seropts(options)
    mut = returning HFactory.createMutator(@keyspace, ks) do |m|
      columns.map do |k, nv|
        nv.map do |sc_name, v|
          column = create_column(sc_name, v.inject({}){|acc,e| acc.merge({e => e})}, options) 
          m.addSubDelete k, column_family, column
        end
      end 
    end
    mut.execute
  end
 

  private

  # e.g.
  # ks, ss, ns, vs = *seropts(options)
  def seropts(opts)
    [serializer(opts[:k_serializer]),
     serializer(opts[:s_serializer]),
     serializer(opts[:n_serializer]),
     serializer(opts[:v_serializer])]
  end
end
