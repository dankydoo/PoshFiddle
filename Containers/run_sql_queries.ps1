#
# do_shit.ps1
#

('System.Data.SqlClient', 'System') |  %{ [System.Reflection.Assembly]::LoadWithPartialName($_) | Out-Null; };


$connectionString = 'Data Source=(localdb)\MSSQLLocalDB;Initial Catalog=TestDatabase;Integrated Security=True;Connect Timeout=30;Encrypt=False;TrustServerCertificate=False;ApplicationIntent=ReadWrite;MultiSubnetFailover=False';
$hostname = 'localhost';


$connection = New-Object System.Data.SqlClient.SqlConnection -ArgumentList $connectionString;
$adapter = New-Object -TypeName System.Data.SqlClient.SqlDataAdapter -ArgumentList 'dbo.sp_generate_merge',$connection;
$adapter.SelectCommand.CommandType = [System.Data.CommandType]::StoredProcedure;
$ds = New-Object System.Data.DataSet

#you would start a loop here
$tableName = 'TestTable'

$connection.Open() | Out-Null;
#you can do a bunch of stuff to the param if you want
$tableNameParam = $adapter.SelectCommand.Parameters.Add('table_name', $tableName);




$adapter.Fill($ds) | Out-Null;

[xml]$mergeStatementXml = $ds.Tables[0].Rows[0][0];
Write-Host -BackgroundColor Cyan -ForegroundColor Blue $mergeStatementXml.OuterXml
#noxml
$mergeStatementSql = $mergeStatementXml.ChildNodes[0].InnerText;
Write-Host -BackgroundColor Red -ForegroundColor Yellow $mergeStatementSql

#output the script? fix the path
$mergeStatementSql | Out-File -FilePath ./merge.sql -Force


$connection.Close();