require "test_helper"

class ClientTest < TrilogyTest
  def test_trilogy_connected_host
    client = new_tcp_client
    # Since this method depends on the hostname of the machine,
    # and therefore isn't constant, we just assert that it's set.
    assert client.connected_host
  ensure
    ensure_closed client
  end

  def test_trilogy_connect_tcp
    client = new_tcp_client
    refute_nil client
  ensure
    ensure_closed client
  end

  def test_trilogy_connect_tcp_string_host
    assert_raises TypeError do
      new_tcp_client host: :localhost
    end
  end

  def test_trilogy_connect_with_native_password_auth_switch
    client = new_tcp_client username: "native"
    refute_nil client
  ensure
    ensure_closed client
  end

  def test_trilogy_connect_tcp_fixnum_port
    assert_raises TypeError do
      new_tcp_client port: "13306"
    end
  end

  def test_trilogy_connect_tcp_to_wrong_port
    e = assert_raises Trilogy::ConnectionError do
      new_tcp_client port: 13307
    end
    assert_equal "Connection refused - trilogy_connect - unable to connect to #{DEFAULT_HOST}:13307", e.message
  end

  def test_trilogy_connect_unix_socket
    return skip unless ["127.0.0.1", "localhost"].include?(DEFAULT_HOST)

    socket = new_tcp_client.query("SHOW VARIABLES LIKE 'socket'").to_a[0][1]

    assert File.exist?(socket), "cound not find socket at #{socket}"

    client = new_unix_client(socket)
    refute_nil client
  ensure
    ensure_closed client
  end

  def test_trilogy_connect_unix_socket_string_path
    assert_raises TypeError do
      new_unix_client socket: :opt_boxen_data_mysql_socket
    end
  end

  def test_trilogy_connection_options
    client = new_tcp_client

    expected_connection_options = {
      host: DEFAULT_HOST,
      port: DEFAULT_PORT,
      username: DEFAULT_USER,
      password: DEFAULT_PASS,
      ssl: true,
      ssl_mode: 4,
      tls_min_version: 3,
    }
    assert_equal expected_connection_options, client.connection_options
  end

  def test_trilogy_ping
    client = new_tcp_client
    assert client.ping
  ensure
    ensure_closed client
  end

  def test_trilogy_ping_after_close_returns_false
    client = new_tcp_client
    assert client.ping
    client.close
    assert_raises Trilogy::ConnectionClosed do
      client.ping
    end
  ensure
    ensure_closed client
  end

  def test_trilogy_change_db
    client = new_tcp_client
    assert client.change_db "test"
  ensure
    ensure_closed client
  end

  def test_trilogy_change_db_after_close_raises
    client = new_tcp_client
    assert client.change_db "test"
    client.close
    assert_raises Trilogy::ConnectionClosed do
      refute client.change_db "test"
    end
  ensure
    ensure_closed client
  end

  def test_trilogy_query
    client = new_tcp_client
    assert client.query "SELECT 1"
  ensure
    ensure_closed client
  end

  def test_trilogy_query_values_vs_query_allocations
    client = new_tcp_client
    client.query_with_flags("SELECT 1", client.query_flags) # warm up

    row_count = 1000
    sql = (1..row_count).map{|i| "SELECT #{i}" }.join(" UNION ")

    query_allocations = allocations { client.query_with_flags(sql, client.query_flags) }
    flatten_rows_allocations = allocations { client.query_with_flags(sql, client.query_flags | Trilogy::QUERY_FLAGS_FLATTEN_ROWS) }

    assert_equal query_allocations - row_count, flatten_rows_allocations
  end

  def test_trilogy_more_results_exist?
    client = new_tcp_client(multi_statement: true)
    create_test_table(client)

    refute_predicate client, :more_results_exist?
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4')")
    refute_predicate client, :more_results_exist?

    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4'); INSERT INTO trilogy_test (int_test) VALUES ('1')")
    assert_predicate client, :more_results_exist?
  end

  def test_trilogy_next_result
    client = new_tcp_client(multi_statement: true)
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4')")
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('3')")
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('1')")

    results = []

    results << client.query("SELECT id, int_test FROM trilogy_test WHERE id = 1; SELECT id, int_test FROM trilogy_test WHERE id IN (2, 3); SELECT id, int_test FROM trilogy_test")

    while (client.more_results_exist?) do
      results << client.next_result
    end

    assert_equal 3, results.length

    rs1, rs2, rs3 = results

    assert_equal [[1, 4]], rs1.rows
    assert_equal [[2, 3], [3, 1]], rs2.rows
    assert_equal [[1, 4], [2, 3], [3, 1]], rs3.rows
  end

  def test_trilogy_next_result_when_no_more_results_exist
    client = new_tcp_client(multi_statement: true)
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4')")

    result = client.query("SELECT id, int_test FROM trilogy_test")
    next_result = client.next_result

    assert_equal [{ "id" => 1, "int_test" => 4 }], result.each_hash.to_a

    assert_nil next_result
  end

  def test_trilogy_multiple_results
    client = new_tcp_client
    create_test_table(client)

    client.query("DROP PROCEDURE IF EXISTS test_proc")
    client.query("CREATE PROCEDURE test_proc() BEGIN SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2'; END")

    result = client.query("CALL test_proc()")

    assert_equal([{ 'set_1' => 1 }], result.each_hash.to_a)
    assert client.more_results_exist?

    result = client.next_result
    assert_equal([{ 'set_2' => 2 }], result.each_hash.to_a)

    result = client.next_result
    assert_equal([], result.each_hash.to_a)

    refute client.more_results_exist?
  end

  def test_trilogy_multiple_results_doesnt_allow_multi_statement_queries
    client = new_tcp_client
    create_test_table(client)

    assert_raises(Trilogy::QueryError) do
      # Multi statement queries are not supported
      client.query("SELECT 1 AS 'set_1'; SELECT 2 AS 'set_2';")
    end
  end

  def test_trilogy_next_result_raises_when_response_has_error
    client = new_tcp_client(multi_statement: true)
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4')")

    _rs1 = client.query("SELECT id, int_test FROM trilogy_test; SELECT non_existent_column FROM trilogy_test")

    assert_raises(Trilogy::ProtocolError) do
      client.next_result
    end
  end

  def test_trilogy_query_values
    client = new_tcp_client
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4')")
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('3')")
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('1')")

    result = client.query_with_flags("SELECT id, int_test FROM trilogy_test", client.query_flags | Trilogy::QUERY_FLAGS_FLATTEN_ROWS)

    assert_equal ["id", "int_test"], result.fields
    assert_equal [1, 4, 2, 3, 3, 1], result.rows
  end

  def test_trilogy_set_server_option
    client = new_tcp_client
    create_test_table(client)

    client.set_server_option(Trilogy::SET_SERVER_MULTI_STATEMENTS_ON)
    client.set_server_option(Trilogy::SET_SERVER_MULTI_STATEMENTS_OFF)
  end

  def test_trilogy_set_server_option_with_invalid_option
    client = new_tcp_client
    create_test_table(client)

    e = assert_raises do
      client.set_server_option(42)
    end

    assert_instance_of(Trilogy::ProtocolError, e)
    assert_match(/1047: Unknown command/, e.message)
  end

  def test_trilogy_set_server_option_multi_statement
    # Start with multi_statement disabled, enable it during connection
    client = new_tcp_client
    create_test_table(client)

    e = assert_raises do
      client.query("INSERT INTO trilogy_test (int_test) VALUES ('4'); INSERT INTO trilogy_test (int_test) VALUES ('1')")
    end

    assert_instance_of(Trilogy::QueryError, e)
    assert_match(/1064: You have an error in your SQL syntax/, e.message)

    client.set_server_option(Trilogy::SET_SERVER_MULTI_STATEMENTS_ON)
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4'); INSERT INTO trilogy_test (int_test) VALUES ('1')")
    client.next_result while client.more_results_exist?

    # Start with multi_statement enabled, disable it during connection
    client = new_tcp_client(multi_statement: true)
    create_test_table(client)
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4'); INSERT INTO trilogy_test (int_test) VALUES ('1')")
    client.next_result while client.more_results_exist?
    client.set_server_option(Trilogy::SET_SERVER_MULTI_STATEMENTS_OFF)

    e = assert_raises do
      client.query("INSERT INTO trilogy_test (int_test) VALUES ('4'); INSERT INTO trilogy_test (int_test) VALUES ('1')")
    end

    assert_instance_of(Trilogy::QueryError, e)
    assert_match(/1064: You have an error in your SQL syntax/, e.message)
  end

  def test_trilogy_query_result_object
    client = new_tcp_client

    result = client.query "SELECT 1 AS a, 2 AS b"

    assert_equal ["a", "b"], result.fields
    assert_equal [[1, 2]], result.rows
    assert_equal [{ "a" => 1, "b" => 2 }], result.each_hash.to_a
    assert_equal [[1, 2]], result.to_a
    assert_kind_of Float, result.query_time
    assert_in_delta 0.1, result.query_time, 0.1
  ensure
    ensure_closed client
  end

  def test_trilogy_query_after_close_raises
    client = new_tcp_client
    assert client.query "SELECT 1"
    client.close
    assert_raises Trilogy::ConnectionClosed do
      refute client.query "SELECT 1"
    end
  ensure
    ensure_closed client
  end

  def test_trilogy_last_insert_id
    client = new_tcp_client
    create_test_table(client)

    client.query "TRUNCATE trilogy_test"
    result_a = client.query "INSERT INTO trilogy_test (varchar_test) VALUES ('a')"
    assert result_a
    assert_equal 1, client.last_insert_id

    result_b = client.query "INSERT INTO trilogy_test (varchar_test) VALUES ('b')"
    assert result_b
    assert_equal 2, client.last_insert_id

    result_select = client.query("SELECT varchar_test FROM trilogy_test")
    assert_equal 0, client.last_insert_id

    assert_equal 1, result_a.last_insert_id
    assert_equal 2, result_b.last_insert_id
    assert_nil result_select.last_insert_id
  ensure
    ensure_closed client
  end

  def test_trilogy_affected_rows
    client = new_tcp_client
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (varchar_test, int_test) VALUES ('a', 1)")

    result_unchanged = client.query("UPDATE trilogy_test SET int_test = 1 WHERE varchar_test = 'a'")
    assert_equal 0, client.affected_rows

    result_changed = client.query("UPDATE trilogy_test SET int_test = 2 WHERE varchar_test = 'a'")
    assert_equal 1, client.affected_rows

    result_select = client.query("SELECT int_test FROM trilogy_test WHERE varchar_test = 'a'")
    assert_equal 0, client.affected_rows

    assert_equal 0, result_unchanged.affected_rows
    assert_equal 1, result_changed.affected_rows
    assert_nil result_select.affected_rows
  ensure
    ensure_closed client
  end

  def test_trilogy_affected_rows_in_found_rows_mode
    client = new_tcp_client(:found_rows => true)
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (varchar_test, int_test) VALUES ('a', 1)")

    result_unchanged = client.query("UPDATE trilogy_test SET int_test = 1 WHERE varchar_test = 'a'")
    assert_equal 1, client.affected_rows

    result_changed = client.query("UPDATE trilogy_test SET int_test = 2 WHERE varchar_test = 'a'")
    assert_equal 1, client.affected_rows

    result_select = client.query("SELECT int_test FROM trilogy_test WHERE varchar_test = 'a'")
    assert_equal 0, client.affected_rows

    assert_equal 1, result_unchanged.affected_rows
    assert_equal 1, result_changed.affected_rows
    assert_nil result_select.affected_rows
  ensure
    ensure_closed client
  end

  def test_trilogy_warning_count
    client = new_tcp_client
    create_test_table(client)

    result = client.query "INSERT INTO trilogy_test (varchar_test) VALUES ('a')"
    assert result
    assert_equal 0, client.warning_count

    result = client.query "SELECT 1 + 2"
    assert result
    assert_equal 0, client.warning_count

    # this field is only 10 characters wide
    longer_val = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    result = client.query "INSERT INTO trilogy_test (varchar_test) VALUES ('#{longer_val}')"
    assert result
    assert_equal 1, client.warning_count
  ensure
    ensure_closed client
  end

  def test_trilogy_close_twice_succeeds
    client = new_tcp_client
    assert_nil client.close
    assert_nil client.close
  end

  def test_trilogy_escape
    client = new_tcp_client

    assert_equal "hello", client.escape("hello")

    assert_equal "\\\"\\0\\'\\\\\\n\\r\\Z",
      client.escape("\"\0\'\\\n\r\x1A")

    assert_equal "\xff", client.escape("\xff")

    str = "binary string".encode(Encoding::Windows_1252)
    assert_equal Encoding::Windows_1252, client.escape(str).encoding
  ensure
    ensure_closed client
  end

  def test_trilogy_escape_ascii_compat
    client = new_tcp_client

    assert_raises Encoding::CompatibilityError do
      client.escape("'\"\\".encode("UTF-16LE"))
    end

  ensure
    ensure_closed client
  end

  def test_trilogy_escape_no_blackslash_escapes
    client = new_tcp_client

    client.query("SET SQL_MODE=NO_BACKSLASH_ESCAPES")

    assert_equal "hello '' world", client.escape("hello ' world")
  ensure
    ensure_closed client
  end

  def test_trilogy_closed?
    client = new_tcp_client

    refute_predicate client, :closed?

    client.close

    assert_predicate client, :closed?
  ensure
    ensure_closed client
  end

  def test_read_timeout
    client = new_tcp_client(read_timeout: 0.1)

    assert_raises Trilogy::TimeoutError do
      client.query("SELECT SLEEP(1)")
    end
  ensure
    ensure_closed client
  end

  def test_adjustable_read_timeout
    client = new_tcp_client(read_timeout: 5)
    assert client.query("SELECT SLEEP(0.2)");
    client.read_timeout = 0.1
    assert_equal 0.1, client.read_timeout
    assert_raises Trilogy::TimeoutError do
      client.query("SELECT SLEEP(1)")
    end
  ensure
    ensure_closed client
  end

  def test_read_timeout_closed_connection
    client = new_tcp_client(read_timeout: 5)
    client.close
    ensure_closed client

    assert_raises Trilogy::ConnectionClosed do
      client.read_timeout
    end

    assert_raises Trilogy::ConnectionClosed do
      client.read_timeout = 42
    end
  end

  def test_adjustable_write_timeout
    client = new_tcp_client(write_timeout: 5)
    assert_equal 5.0, client.write_timeout
    client.write_timeout = 0.1
    assert_equal 0.1, client.write_timeout
  ensure
    ensure_closed client
  end

  def test_write_timeout_closed_connection
    client = new_tcp_client
    client.close
    ensure_closed client

    assert_raises Trilogy::ConnectionClosed do
      client.write_timeout
    end

    assert_raises Trilogy::ConnectionClosed do
      client.write_timeout = 42
    end
  end

  def test_connect_timeout
    serv = TCPServer.new(0)
    port = serv.addr[1]

    assert_raises Trilogy::TimeoutError do
      new_tcp_client(host: "127.0.0.1", port: port, connect_timeout: 0.1)
    end
  ensure
    ensure_closed serv
  end

  def test_large_query
    client = new_tcp_client

    size = 1_000_000

    assert_equal size, client.query("SELECT '#{"1" * size}'").to_a[0][0].size
  ensure
    ensure_closed client
  end

  def test_cast_exception_during_query_does_not_close_the_connection
    client = new_tcp_client
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (date_time_test) VALUES ('4321-01-01 00:00:00')")
    client.query("INSERT INTO trilogy_test (date_time_test) VALUES ('1234-00-00 00:00:00')")
    client.query("INSERT INTO trilogy_test (date_time_test) VALUES ('2345-12-31 00:00:00')")

    err = assert_raises Trilogy::Error do
      client.query("SELECT date_time_test FROM trilogy_test")
    end
    assert_equal "Invalid date: 1234-00-00 00:00:00", err.message

    err = assert_raises Trilogy::Error do
      client.ping
    end
    assert_includes err.message, "TRILOGY_CLOSED_CONNECTION"
  end

  def test_client_side_timeout_checks_result_set
    client = new_tcp_client
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (varchar_test, int_test) VALUES ('a', 2)")
    client.query("INSERT INTO trilogy_test (varchar_test, int_test) VALUES ('b', 2)")
    client.query("INSERT INTO trilogy_test (varchar_test, int_test) VALUES ('c', 2)")

    assert_raises Timeout::Error do
      Timeout::timeout(0.1) do
        client.query("SELECT SLEEP(1)")
      end
    end

    err = assert_raises Trilogy::Error do
      client.query("SELECT varchar_test FROM trilogy_test WHERE int_test = 2").to_a
    end

    assert_includes err.message, "TRILOGY_CLOSED_CONNECTION"
  end

  def assert_elapsed(expected, delta)
    start = Process.clock_gettime Process::CLOCK_MONOTONIC
    yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert_in_delta(expected, elapsed, delta)
  end

  def test_timeout_deadlines
    assert_elapsed(0.1, 0.3) do
      client = new_tcp_client

      assert_raises Timeout::Error do
        Timeout::timeout(0.1) do
          client.query("SELECT SLEEP(1)")
        end
      end

      err = assert_raises Trilogy::Error do
        client.query("SELECT 'hello'").to_a
      end

      assert_includes err.message, "TRILOGY_CLOSED_CONNECTION"
    end
  end

  def test_timeout_error
    client_1 = new_tcp_client
    client_2 = new_tcp_client

    create_test_table(client_1)
    client_2.change_db("test")

    client_1.query("INSERT INTO trilogy_test (varchar_test) VALUES ('a')")
    client_1.query("BEGIN")
    client_1.query("SELECT * FROM trilogy_test FOR UPDATE")

    client_2.query("SET SESSION innodb_lock_wait_timeout = 1;")
    assert_raises Trilogy::TimeoutError do
      client_2.query("SELECT * FROM trilogy_test FOR UPDATE")
    end
  ensure
    ensure_closed(client_1)
    ensure_closed(client_2)
  end

  def test_connection_error
    err = assert_raises Trilogy::ConnectionError do
      new_tcp_client(username: "native", password: "incorrect")
    end

    assert_includes err.message, "Access denied for user 'native'"
  end

  def test_connection_closed_error
    client = new_tcp_client

    client.close

    err = assert_raises Trilogy::ConnectionClosed do
      client.query("SELECT 1");
    end

    assert_equal "Attempted to use closed connection", err.message
  end

  def test_query_error
    client = new_tcp_client

    err = assert_raises Trilogy::QueryError do
      client.query("not legit sqle")
    end

    assert_equal 1064, err.error_code
    assert_includes err.message, "You have an error in your SQL syntax"

    # test that the connection is not closed due to 'routine' errors
    assert client.ping
  ensure
    ensure_closed client
  end

  def test_releases_gvl
    client = new_tcp_client

    assert_raises Timeout::Error do
      Timeout.timeout(0.1) do
        client.query("SELECT SLEEP(1)")
      end
    end

    err = assert_raises Trilogy::Error do
      client.ping
    end

    assert_includes err.message, "TRILOGY_CLOSED_CONNECTION"
  end

  USR1 = Class.new(StandardError)

  def test_interruptible_when_releasing_gvl
    client = new_tcp_client

    old_usr1 = trap "USR1" do
      raise USR1
    end

    pid = fork do
      sleep 0.1
      Process.kill(:USR1, Process.ppid)
    end

    assert_raises USR1 do
      client.query("SELECT SLEEP(1)")
    end
  ensure
    Process.wait(pid)
    trap "USR1", old_usr1
    ensure_closed client
  end

  def test_in_transaction_status
    client = new_tcp_client
    assert !client.in_transaction?
    client.query "START TRANSACTION"
    assert client.in_transaction?
    client.query "COMMIT"
    assert !client.in_transaction?
  ensure
    ensure_closed client
  end

  def test_server_version
    client = new_tcp_client
    assert_match %r{\A\d+\.\d+\.\d+}, client.server_version
  end

  def test_server_info
    client = new_tcp_client
    server_info = client.server_info

    assert_kind_of 0.class, server_info[:id]
    assert_kind_of String, server_info[:version]
  end

  def test_connect_by_multiple_names
    return skip unless ["127.0.0.1", "localhost"].include?(DEFAULT_HOST)

    Trilogy.new(host: "127.0.0.1")
    Trilogy.new(host: "localhost")
  end

  def set_max_allowed_packet(size)
    client = new_tcp_client
    client.query "SET GLOBAL max_allowed_packet = #{size}"
  ensure
    ensure_closed client
  end

  def test_trilogy_max_allowed_packet_with_default_config
    set_max_allowed_packet(8 * 1024 * 1024)

    client = new_tcp_client

    assert_equal 8 * 1024 * 1024, client.max_allowed_packet
  end

  def test_trilogy_max_allowed_packet_with_local_max_allowed_packet
    set_max_allowed_packet(8 * 1024 * 1024)

    client = new_tcp_client(max_allowed_packet: 4 * 1024 * 1024)

    assert_equal 4 * 1024 * 1024, client.max_allowed_packet
  end

  def test_packet_size_lower_than_trilogy_max_packet_len
    set_max_allowed_packet(4 * 1024 * 1024) # TRILOGY_MAX_PACKET_LEN is 16MB

    client = new_tcp_client

    create_test_table(client)
    client.query "TRUNCATE trilogy_test"

    result = client.query "INSERT INTO trilogy_test (blob_test) VALUES ('#{"x" * (1 * 1024 * 1024)}')"
    assert result
    assert_equal 1, client.last_insert_id

    result = client.query "INSERT INTO trilogy_test (blob_test) VALUES ('#{"x" * (2 * 1024 * 1024)}')"
    assert result
    assert_equal 2, client.last_insert_id

    exception = assert_raises Trilogy::QueryError do
        client.query "INSERT INTO trilogy_test (blob_test) VALUES ('#{"x" * (4 * 1024 * 1024)}')"
    end

    assert_equal exception.message, "Query is too big 4194352 vs #{4 * 1024 * 1024}. Consider increasing max_allowed_packet."
  ensure
    ensure_closed client
  end

  def test_packet_size_greater_than_trilogy_max_packet_len
    set_max_allowed_packet(32 * 1024 * 1024) # TRILOGY_MAX_PACKET_LEN is 16MB

    client = new_tcp_client

    create_test_table(client)
    client.query "TRUNCATE trilogy_test"

    result = client.query "INSERT INTO trilogy_test (blob_test) VALUES ('#{"x" * (15 * 1024 * 1024)}')"
    assert result
    assert_equal 1, client.last_insert_id

    result = client.query "INSERT INTO trilogy_test (blob_test) VALUES ('#{"x" * (31 * 1024 * 1024)}')"
    assert result
    assert_equal 2, client.last_insert_id

    exception = assert_raises Trilogy::QueryError do
        client.query "INSERT INTO trilogy_test (blob_test) VALUES ('#{"x" * (32 * 1024 * 1024)}')"
    end

    assert_equal exception.message, "Query is too big 33554480 vs #{32 * 1024 * 1024}. Consider increasing max_allowed_packet."
  ensure
    ensure_closed client
  end

  def test_too_many_connections
    connection_error_packet = [
      0x17, 0x00, 0x00, 0x00, 0xff, 0x10, 0x04, 0x54,
      0x6f, 0x6f, 0x20, 0x6d, 0x61, 0x6e, 0x79, 0x20,
      0x63, 0x6f, 0x6e, 0x6e, 0x65, 0x63, 0x74, 0x69,
      0x6f, 0x6e, 0x73
    ].pack("c*")

    fake_server = TCPServer.new("127.0.0.1", 0)
    _, fake_port = fake_server.addr

    accept_thread = Thread.new do
      # this will block until we connect below this thread creation
      write_side = fake_server.accept

      write_side.write(connection_error_packet)

      write_side.close
    end

    ex = assert_raises Trilogy::ProtocolError do
      new_tcp_client(host: "127.0.0.1", port: fake_port)
    end

    assert_equal 1040, ex.error_code
    assert ex.is_a?(Trilogy::DatabaseError)
  ensure
    accept_thread.join
    fake_server.close
  end

  def test_no_reconnect_on_error
    client = new_tcp_client

    connection_id = client.query("SELECT CONNECTION_ID()").to_a.first.first

    assert_raises Trilogy::ProtocolError do
      client.query("SELECT /*+ MAX_EXECUTION_TIME(10) */ WAIT_FOR_EXECUTED_GTID_SET('01e4737c-9752-11e8-a17a-d40393d98615:1-76747', 1.01)")
    end

    assert_equal client.query("SELECT CONNECTION_ID()").first.first, connection_id
  end

  def test_gtid_support
    client = new_tcp_client

    if client.query("SELECT @@GLOBAL.log_bin").first == [0]
      return skip("bin_log needs to be enabled for GTID support")
    end

    # Run these in case we're still in OFF mode to go step by step to ON
    client.query "SET GLOBAL server_id = 1"
    client.query "SET GLOBAL gtid_mode = OFF_PERMISSIVE" rescue nil
    client.query "SET GLOBAL gtid_mode = ON_PERMISSIVE" rescue nil
    client.query "SET GLOBAL enforce_gtid_consistency = ON"
    client.query "SET GLOBAL gtid_mode = ON"
    client.query "SET SESSION session_track_gtids = OWN_GTID"

    create_test_table(client)
    client.query "TRUNCATE trilogy_test"

    result = client.query "INSERT INTO trilogy_test (varchar_test) VALUES ('a')"
    last_gtid = client.last_gtid

    result = client.query "SHOW GLOBAL VARIABLES LIKE 'gtid_executed'"
    gtid_set = result.rows.first[1]
    gtid, set = gtid_set.split(":")
    last = set.split("-").last

    assert_equal "#{gtid}:#{last}", last_gtid
  end

  def test_connection_refused
    fake_server = TCPServer.new("127.0.0.1", 0)
    _, fake_port = fake_server.addr
    fake_server.close

    assert_raises Trilogy::ConnectionError do
      new_tcp_client(host: "127.0.0.1", port: fake_port)
    end
  end

  def test_connection_invalid_dns
    ex = assert_raises Trilogy::ConnectionError do
      new_tcp_client(host: "mysql.invalid", port: 3306)
    end
    assert_equal "trilogy_connect - unable to connect to mysql.invalid:3306: TRILOGY_DNS_ERROR", ex.message
  end

  def test_memsize
    require 'objspace'
    client = new_tcp_client
    assert_kind_of Integer, ObjectSpace.memsize_of(client)
  end

  def test_trilogy_int_sum_query
    client = new_tcp_client
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (int_test) VALUES ('4')")
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('3')")
    client.query("INSERT INTO trilogy_test (int_test) VALUES ('1')")

    result = client.query("SELECT SUM(int_test) FROM trilogy_test")
    sum = result.rows[0][0]

    assert sum.is_a?(Integer)
    assert_equal 8, sum
  end

  def test_trilogy_decimal_sum_query
    client = new_tcp_client
    create_test_table(client)

    client.query("INSERT INTO trilogy_test (decimal_test) VALUES ('4')")
    client.query("INSERT INTO trilogy_test (decimal_test) VALUES ('3')")
    client.query("INSERT INTO trilogy_test (decimal_test) VALUES ('1')")

    result = client.query("SELECT SUM(decimal_test) FROM trilogy_test")
    sum = result.rows[0][0]

    assert sum.is_a?(BigDecimal)
    assert_equal 8, sum
  end

  def test_close_terminate_parent_connection
    skip("Fork isn't supported on this platform") unless Process.respond_to?(:fork)

    client = new_tcp_client
    assert_equal [1], client.query("SELECT 1").to_a.first

    pid = fork do
      client.close
      exit!(0) # exit! to bypass minitest at_exit
    end
    _, status = Process.wait2(pid)
    assert_predicate status, :success?

    error = assert_raises Trilogy::QueryError do
      client.query("SELECT 1")
    end
    assert_match "TRILOGY_CLOSED_CONNECTION", error.message
  end

  def test_discard_doesnt_terminate_parent_connection
    skip("Fork isn't supported on this platform") unless Process.respond_to?(:fork)

    client = new_tcp_client
    assert_equal [1], client.query("SELECT 1").to_a.first

    pid = fork do
      client.discard!
      exit!(0) # exit! to bypass minitest at_exit
    end
    _, status = Process.wait2(pid)
    assert_predicate status, :success?

    # The client is still usable after a child discarded it.
    assert_equal [1], client.query("SELECT 1").to_a.first
  end

  def test_no_character_encoding
    client = new_tcp_client

    assert_equal "utf8mb4", client.query("SELECT @@character_set_client").first.first
    assert_equal "utf8mb4", client.query("SELECT @@character_set_results").first.first
    assert_equal "utf8mb4", client.query("SELECT @@character_set_connection").first.first
    assert_equal "utf8mb4_general_ci", client.query("SELECT @@collation_connection").first.first
  end

  def test_bad_character_encoding
    err = assert_raises ArgumentError do
      new_tcp_client(encoding: "invalid")
    end
    assert_equal "Unknown or unsupported encoding: invalid", err.message
  end

  def test_character_encoding
    client = new_tcp_client(encoding: "cp932")

    assert_equal "cp932", client.query("SELECT @@character_set_client").first.first
    assert_equal "cp932", client.query("SELECT @@character_set_results").first.first
    assert_equal "cp932", client.query("SELECT @@character_set_connection").first.first
    assert_equal "cp932_japanese_ci", client.query("SELECT @@collation_connection").first.first

    expected = "こんにちは".encode(Encoding::CP932)
    assert_equal expected, client.query("SELECT 'こんにちは'").to_a.first.first
  end

  def test_character_encoding_handles_binary_queries
    client = new_tcp_client
    expected = "\xff".b

    result = client.query("SELECT _binary'#{expected}'").to_a.first.first
    assert_equal expected, result
    assert_equal Encoding::BINARY, result.encoding

    result = client.query("SELECT '#{expected}'").to_a.first.first
    assert_equal expected.dup.force_encoding(Encoding::UTF_8), result
    assert_equal Encoding::UTF_8, result.encoding

    client = new_tcp_client(encoding: "cp932")
    result = client.query("SELECT '#{expected}'").to_a.first.first
    assert_equal expected.dup.force_encoding(Encoding::Windows_31J), result
    assert_equal Encoding::Windows_31J, result.encoding
  end
end
