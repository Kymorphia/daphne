module utils;

import ddbc : Connection;


void executeSql(Connection conn, string sql)
{
  auto stmt = conn.createStatement;
  scope(exit) stmt.close;

  stmt.executeUpdate(sql);
}
