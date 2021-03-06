class Hash
  # path is an array of hash keys
  # This method deletes a path of hash keys, with each step in the path
  # being a recursively deeper key in a hash tree.
  # Returns the possibly modified hash.
  def delete_key_path( path )
    if path.length > 1
      subtree = self[ path[ 0 ] ]
      if subtree.respond_to?( :delete_key_path )
        subtree.delete_key_path( path[ 1..-1 ] )
        if subtree.empty?
          delete( path[ 0 ] )
        end
      end
    elsif path.length == 1
      delete( path[ 0 ] )
    end

    self
  end

  def set_key_path( path, leaf )
    if path.length > 1
      node = self[ path[ 0 ] ]
      if not node.respond_to?( :set_key_path )
        node = self[ path[ 0 ] ] = Hash.new
      end
      node.set_key_path( path[ 1..-1 ], leaf )
    elsif path.length == 1
      self[ path[ 0 ] ] = leaf
    end

    self
  end

  def get_node( path )
    node = self[ path[ 0 ] ]
    if path.length > 1
      if node and node.respond_to?( :get_node )
        return node.get_node( path[ 1..-1 ] )
      end
    elsif path.length == 1
      return node
    end

    nil
  end

  def get_leaf( path )
    node = get_node( path )
    if node.respond_to?( :get_node )
      # Only want a leaf node
      nil
    else
      node
    end
  end

  def leaves( _leaves = Set.new )
    each_value do |value|
      if value.respond_to?( :leaves )
        _leaves.merge value.leaves( _leaves )
      else
        _leaves << value
      end
    end

    _leaves
  end

  def paths_and_leaves( path_so_far = [], _paths_and_leaves = Set.new )
    each do |key, value|
      if value.respond_to?( :paths_and_leaves )
        _paths_and_leaves.merge(
          value.paths_and_leaves(
            path_so_far + [ key ],
            _paths_and_leaves
          )
        )
      else
        _paths_and_leaves << {
          :path => path_so_far + [ key ],
          :leaf => value
        }
      end
    end

    _paths_and_leaves
  end

  def each_path_and_leaf( path_so_far = [] )
    each do |key, value|
      if value.respond_to?( :each_path_and_leaf )
        value.each_path_and_leaf( path_so_far + [ key ] ) { |path, leaf| yield( path, leaf ) }
      else
        yield( path_so_far + [ key ], value )
      end
    end
  end

  # Implement Ruby 1.9's Hash#key for Ruby 1.8
  if ! method_defined?( :key )
    def key( *args )
      index( *args )
    end
  end
end

