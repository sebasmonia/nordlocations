;;;; nordvpn-api.lisp
;;; Everything related to consuming the API lives here

(in-package #:nordvpn-api)

(defvar *nord-api-url* "https://api.nordvpn.com/v1/servers" "Base URL of the NordVPN API.")

(defvar *api-call-limit* 5000
  "Number of items to return per API call. Currently used in when fetching by country.")

(defvar *config-file-url-template* "https://downloads.nordcdn.com/configs/files/ovpn_legacy/servers/~a.udp1194.ovpn"
  "Template URL to download the OpenVPN configuration files, add hostname and voilà!")

(defvar *temp-download-template* "/tmp/nordvpn-client-~a.ovpn"
  "Template to download the VPN definition file.
I should replace this with UIOP or CL-FAD temp file facilities.")

(defun get-countries-cities ()
  "Fetch and parse the list of countries and their cities."
  (flet ((extract-countries-cities (country-ht)
           `((:name . ,(gethash "name" country-ht))
             (:id . ,(gethash "id" country-ht))
             (:cities . ,(loop for city-ht across (gethash "cities" country-ht)
                               collect (gethash "name" city-ht))))))
    (let ((response (drakma:http-request (format nil "~a~a" *nord-api-url* "/countries")
                                         :want-stream t)))
      (loop for parsed-node across (shasht:read-json* :stream response)
            collect (extract-countries-cities parsed-node)))))

(defun get-best-server-current-location ()
  "Get the best server for the current location, or rather what NordVPN thinks is your location."
  (let ((ten-best-servers (shasht:read-json* :stream
                                             (drakma:http-request (format nil
                                                                          "~a/recommendations?limit=10"
                                                                          *nord-api-url*)
                                                                  :want-stream t))))
    ;; Servers returned are sorted by load. Return the first match...
    (elt ten-best-servers 0)))

(defun get-recommended-servers-for-country (country-id)
  "Get the recommended servers for a given COUNTRY-ID."
  ;; I couldn't find online, nor figure out, how to filter by city in the API call, so I am taking
  ;; the same approach I've seen in a few other tools of getting all the servers for a country and
  ;; then filter the lowest-load one that matches the desired city
  (flet ((identity-url-encoder (input-text external-format)
           (declare (ignore external-format))
           input-text))
    (shasht:read-json* :stream (drakma:http-request
                                (format nil
                                        "~a/recommendations?limit=~a&filters%5Bcountry_id%5D=~a"
                                        *nord-api-url*
                                        *api-call-limit*
                                        country-id)
                                :url-encoder #'identity-url-encoder
                                :want-stream t))))

(defun get-best-server-for-city (country-id city-name)
  "Call `get-recommended-servers-for-country' with COUNTRY-ID, and filter the output by CITY-NAME."
  ;; Experimentation shows that the server list is sorted by city name and then load,
  ;; if that stops being the case, this function would need to check the value for "load" too
  (flet ((server-city (s)
           (gethash "name" (gethash "city" (gethash "country" (elt (gethash "locations" s) 0))))))
  (let* ((country-servers (get-recommended-servers-for-country country-id)))
    (loop for a-server across country-servers
          when (string-equal city-name (server-city a-server))
            ;; returning the first match for CITY-NAME, which has the lowest load
            do (return a-server)))))

;; I couldn't solve the EOF SSL errors downloading the file not
;; even changing from dexador to drakma
;; resorted to good ol' curl =/
(defun download-openvpn-config-file (hostname)
  "Download the OpenVPN UDP file to setup a connection to HOSTNAME.
The way this function gets a temp filename to download the ovpn file is really fickle..."
  (let ((download-path (format nil *temp-download-template*
                               (first (uiop:split-string hostname :separator '(#\.))))))
    (uiop:run-program (list "curl" "-o"
                            download-path
                            (format nil *config-file-url-template* hostname)))
      download-path))
