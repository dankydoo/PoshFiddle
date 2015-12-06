

function Invoke-WebRequest([System.Uri]$Uri, $outFileName, $Method) {

    $request = [System.Net.WebRequest]::Create($Uri);
    if($method -ne $null) {
        $request.Method = $Method;
    }

    if($body -ne $null) {
        #implement post method
    }

    $response = $request.GetResponseAsync().Result.GetResponseStream();
    $responseStream = New-Object System.IO.StreamReader $response


    $responseData = $responseStream.ReadToEnd();
    if($outFileName -ne $null) {
        $responseData > $outFileName
    }

    #$responseData
    return $responseData;

}