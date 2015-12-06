#
# Script.ps1
#

$connectionString = 'Data Source=(localdb)\MSSQLLocalDB;Initial Catalog=master;Integrated Security=True;Connect Timeout=30;Encrypt=False;TrustServerCertificate=False;ApplicationIntent=ReadWrite;MultiSubnetFailover=False';
$hostname = 'localhost';

$connection = New-Object System.Data.SqlClient