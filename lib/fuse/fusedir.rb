module FuseFS

    # Helper for filesystem accounting
    class StatsHelper

        # @return [Integer] size of filesystem in bytes
        attr_accessor :max_space
        # @return [Integer] maximum number of (virtual) inodes
        attr_accessor :max_nodes

        # If set true, adjustments that cause space/nodes to exceed
        # the maximums will raise ENOSPC (no space left on device)
        # @return [Boolean]
        attr_accessor :strict

        # @return [Integer] used space in bytes
        attr_reader :space

        # @return [Integer] used inodes (typically count of files and directories)
        attr_reader :nodes

        #
        # @param [Integer] max_space
        # @param [Integer] max_nodes
        # @param [Booleanr] strict
        def initialize(max_space=nil,max_nodes=nil,strict=false)
            @nodes = 0
            @space = 0
            @max_space = max_space
            @max_nodes = max_nodes
            @strict = strict
        end

        # Adjust accumlated statistics
        # @param [Integer] delta_space change in {#space} usage
        # @param [Integer] delta_nodes change in {#nodes} usage
        #
        # @return [void]
        # @raise [Errno::ENOSPC] if {#strict} and adjusted {#space}/{#nodes} would exceed {#max_space} or {#max_nodes}
        def adjust(delta_space,delta_nodes=0)
            @nodes += delta_nodes
            @space += delta_space
            raise Errno::ENOSPC if @strict && ( @nodes >  @max_nodes ||  @space > @max_space )
        end

        # @overload to_statistics()
        #   @return [Array<Integer>] in format expected by {FuseDir#statistics}
        # @overload to_statistics(free_space,free_nodes)
        #   Calculate total space so that free space remains fixed
        #   @param [Integer] free_space available space in bytes
        #   @param [Integer] free_nodes available (virtual) inodes
        #   @return [Array<Integer>] in format expected by {FuseDir#statistics}
        def to_statistics(free_space=nil,free_nodes=nil)
            total_space = free_space ? space + free_space : max_space
            total_nodes = free_nodes ? nodes + free_nodes : max_nodes
            [ @space, @nodes, total_space, total_nodes ]
        end
    end

    # This class is equivalent to using Object.new() as the virtual directory
    # for target for {FuseFS.start}. It exists primarily to document the API
    # but can also be used as a superclass for your filesystem providing sensible defaults
    #
    # == Method call sequences
    #
    # === Stat (getattr)
    #
    # FUSE itself will generally stat referenced files and validate the results
    # before performing any file/directory operations so this sequence is called
    # very often
    #   
    # 1. {#directory?} is checked first
    #    * {#can_write?} OR {#can_mkdir?} with .\_rfusefs_check\_ to determine write permissions
    #    * {#times} is called to determine atime,mtime,ctime info for the directory
    #
    # 2. {#file?} is checked next
    #    * {#can_write?}, {#executable?}, {#size}, {#times} are called to fill out the details
    #
    # 3. otherwise we tell FUSE that the path does not exist
    #
    # === List directory 
    # 
    # FUSE confirms the path is a directory (via stat above) before we call {#contents}
    #
    # FUSE will generally go on to stat each directory entry in the results
    #
    # === Reading files
    #
    # FUSE confirms path is a file before we call {#read_file}
    #
    # For fine control of file access see  {#raw_open}, {#raw_read}, {#raw_close}
    #
    # === Writing files
    #
    # FUSE confirms path for the new file is a directory
    #
    # * {#can_write?} is checked at file open
    # * {#write_to} is called when the file is synced, flushed or closed
    #
    # See also {#raw_open}, {#raw_truncate}, {#raw_write}, {#raw_sync}, {#raw_close}
    #
    # === Deleting files
    #
    # FUSE confirms path is a file before we call {#can_delete?} then {#delete}
    #
    # === Creating directories
    #
    # FUSE confirms parent is a directory before we call {#can_mkdir?} then {#mkdir}
    #
    # === Deleting directories
    #
    # FUSE confirms path is a directory before we call {#can_rmdir?} then {#rmdir}
    #
    # === Renaming files and directories
    #
    # FUSE confirms the rename is valid (eg. not renaming a directory to a file)
    #
    # * Try {#rename} to see if the virtual directory wants to handle this itself
    # * If rename returns false/nil then we try to copy/delete (files only) ie.
    #   * {#file?}(from), {#can_write?}(to), {#can_delete?}(from) and if all true
    #   * {#read_file}(from), {#write_to}(to), {#delete}(from)
    # * otherwise reject the rename
    #
    # === Signals
    #
    # The filesystem can handle a signal by providing a `sig<name>` method. eg 'sighup'
    # {#sigint} and {#sigterm} are handled by default to provide a means to exit the filesystem
    class FuseDir

        # @!method sigint()
        #   @return [void]
        #   Handle the INT signal and exit the filesystem

        # @!method sigterm()
        #   @return [void]
        #   Handle the TERM signal and exit the filesystem

        INIT_TIMES = Array.new(3,0)

        #   base,rest = split_path(path) 
        # @return [Array<String,String>] base,rest. base is the first directory in
        #                                path, and rest is nil> or the remaining path.
        #                                Typically if rest is not nil? you should 
        #                                recurse the paths 
        def split_path(path)
            cur, *rest = path.scan(/[^\/]+/)
            if rest.empty?
                [ cur, nil ]
            else
                [ cur, File::SEPARATOR + File.join(rest) ]
            end
        end

        #   base,*rest = scan_path(path)
        # @return [Array<String>] all directory and file elements in path. Useful
        #                         when encapsulating an entire fs into one object
        def scan_path(path)
            path.scan(/[^\/]+/)
        end

        # @abstract FuseFS api
        # @return [Boolean] true if path is a directory
        def directory?(path);return false;end

        # @abstract FuseFS api
        # @return [Boolean] true if path is a file
        def file?(path);end

        # @abstract FuseFS api
        # @return [Array<String>] array of file and directory names within path
        def contents(path);return [];end

        # @abstract FuseFS api
        # @return [Boolean] true if path is an executable file
        def executable?(path);return false;end

        # File size
        # @abstract FuseFS api
        # @return [Integer] the size in byte of a file (lots of applications rely on this being accurate )
        def size(path); read_file(path).length ;end

        # File time information. RFuseFS extension.
        # @abstract FuseFS api
        # @return [Array<Integer, Time>] a 3 element array [ atime, mtime. ctime ] (good for rsync etc)
        def times(path);return INIT_TIMES;end

        # @abstract FuseFS api
        # @return [String] the contents of the file at path
        def read_file(path);return "";end

        # @abstract FuseFS api
        # @return [Boolean] true if the user can write to file at path
        def can_write?(path);return false;end

        # Write the contents of str to file at path
        # @abstract FuseFS api
        # @return [void]
        def write_to(path,str);end

        # @abstract FuseFS api
        # @return [Boolean] true if the user can delete the file at path
        def can_delete?(path);return false;end

        # Delete the file at path
        # @abstract FuseFS api
        # @return [void]
        def delete(path);end

        # @abstract FuseFS api
        # @return [Boolean] true if user can make a directory at path
        def can_mkdir?(path);return false;end

        # Make a directory at path
        # @abstract FuseFS api
        # @return [void]
        def mkdir(path);end

        # @abstract FuseFS api
        # @return [Boolean] true if user can remove a directory at path
        def can_rmdir?(path);return false;end

        # Remove the directory at path
        # @abstract FuseFS api
        # @return [void]
        def rmdir(path);end

        # Neat toy. Called when a file is touched or has its timestamp explicitly modified
        # @abstract FuseFS api
        # @return [void]
        def touch(path,modtime);end

        # Move a file or directory.
        # @abstract FuseFS api
        # @return [Boolean] true to indicate the rename has been handled,
        #                  otherwise will fallback to copy/delete
        def rename(from_path,to_path);end

        # Raw file access  
        # @abstract FuseFS api
        # @param mode [String] "r","w" or "rw", with "a" if file is opened for append
        # @param rfusefs [Boolean] will be "true" if RFuseFS extensions are available
        # @return [nil] to indicate raw operations are not implemented
        # @return [Object] a filehandle
        #                  Under RFuseFS this object will be passed back in to the other raw
        #                  methods as the optional parameter _raw_
        #
        def raw_open(path,mode,rfusefs = nil);end

        # RFuseFS extension.
        # @abstract FuseFS api
        #
        # @overload raw_truncate(path,offset,raw)
        #  Truncate an open file to offset bytes
        #  @param [String] path
        #  @param [Integer] offset
        #  @param [Object] raw the filehandle returned from {#raw_open}
        #  @return [void]
        #
        # @overload raw_truncate(path,offset)
        #  Optionally truncate a file to offset bytes directly
        #  @param [String] path
        #  @param [Integer] offset
        #  @return [Boolean]
        #    if truncate has been performed, otherwise the truncation will be performed with {#read_file} and {#write_to}
        #
        def raw_truncate(path,offset,raw=nil);end

        # Read _sz_ bytes from file at path (or filehandle raw) starting at offset off
        #
        # @param [String] path
        # @param [Integer] offset
        # @param [Integer] size
        # @param [Object] raw the filehandle returned by {#raw_open}
        # @abstract FuseFS api
        # @return [String] _sz_ bytes contents from file at path (or filehandle raw) starting at offset off
        def raw_read(path,offset,size,raw=nil);end

        # Write _sz_ bytes from file at path (or filehandle raw) starting at offset off
        # @abstract FuseFS api
        # @return [void]
        def raw_write(path,off,sz,buf,raw=nil);end


        # Sync buffered data to your filesystem
        # @param [String] path
        # @param [Boolena] datasync only sync user data, not metadata
        # @param [Object] raw the filehandle return by {#raw_open}
        def raw_sync(path,datasync,raw=nil);end

        # Close the file previously opened at path (or filehandle raw)
        # @abstract FuseFS api
        # @return [void]
        def raw_close(path,raw=nil);end

        # RFuseFS extension.
        # Extended attributes.
        # @param [String] path
        # @return [Hash] extended attributes for this path.
        #   The returned object  will be manipulated directly using :[] :[]=,, :keys and :delete
        #   so the default (a new empty hash on every call) will not retain attributes that are set
        # @abstract FuseFS api
        def xattr(path); {} ; end

        # RFuseFS extensions.
        # File system statistics
        # @param [String] path
        # @return [Array<Integer>] the statistics
        #   used_space (in bytes), used_files, max_space, max_files
        #   See {StatsHelper}
        # @return [RFuse::StatVfs] or raw statistics
        # @abstract FuseFS api
        def statistics(path); [0,0,0,0]; end

        # RFuseFS extension.
        # Called when the filesystem is mounted
        # @return [void]
        def mounted();end

        # RFuseFS extension.
        # Called when the filesystem is unmounted
        # @return [void]
        def unmounted();end


    end

    DEFAULT_FS = FuseDir.new()
end
