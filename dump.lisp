(defpackage :dump
  (:use :common-lisp  :lmdb)
  (:import-from :alexandria :once-only :iota
   :plist-alist :with-gensyms)
  (:import-from :listopia :all :any :split-at)
  (:import-from :ironclad :with-octet-input-stream :with-octet-output-stream
   :with-digesting-stream :digest-length)
  (:import-from :str
   :concat :contains? :join :s-rest :split :starts-with?
   :trim-right :words)
  (:import-from :cl-dbi :with-connection :prepare :execute :fetch-all :fetch)
  (:import-from :trivia :lambda-match :match)
  (:import-from :trivial-utf-8 :string-to-utf-8-bytes :write-utf-8-bytes)
  (:import-from :lmdb :with-env :*env* :get-db :with-txn :put :g3t :uint64-to-octets
		:with-cursor :cursor-first :do-cursor :cursor-del))

(in-package :dump)


;; ENV SETTINGS

(defvar *connection-settings*
  (with-open-file
      (stream
       ;; TODO get this from the command line
       "~/projects/oqo-dump-genenetwork-database/fix-sql-queries/conn.scm")
    (read stream)))

(defvar *blob-hash-digest*
  :sha256)


;; Some helper functions
(defun assoc-ref (alist key &key (test #'equalp))
  "Given an association list ALIST, return the value associated with
KEY."
  (match (assoc key alist :test test)
    ((cons _ value) value)))

(defun plists->csv (plists)
  "Convert a list of PLISTS to a CSV string, with the keys of the PLISTS
being the first row."
  (let* ((keys (mapcar #'car (plist-alist
			      (car plists)))) ; get the keys from the first plist
	 (headers (format nil "~{~A~^,~}" keys))
	 (rows (mapcar (lambda (it)
			 (format nil "~{~A~^,~}"
				 (loop for (key value) on it
				       by #'cddr
				       collect value)))
		       plists)))
    (format nil "~A~%~{~A~%~}" headers rows)))

(defun fetch-results-from-sql (statement &optional params)
  (with-connection
      (conn :mysql
	    :database-name (assoc-ref *connection-settings* 'sql-database)
	    :host (assoc-ref *connection-settings* 'sql-host)
	    :port (assoc-ref *connection-settings* 'sql-port)
	    :username (assoc-ref *connection-settings* 'sql-username)
	    :password (assoc-ref *connection-settings* 'sql-password))
    (let* ((query (prepare conn statement))
	   (query (execute query params)))
      (fetch-all query))))

(defmacro with-sampledata-db ((db database-directory &key write) &body body)
  "Create a new LMDB database in DATABASE-DIRECTORY and execute BODY
with a transaction open on DB."
  (with-gensyms (env)
    (once-only (database-directory write)
      `(with-env (,env ,database-directory
		       :if-does-not-exist :create
		       :map-size (* 100 1024 1024))
	 (let ((,db (get-db nil :env ,env)))
	   (with-txn (:env ,env :write ,write)
	     ,@body))))))


;; Hash functions and operations on bytevectors
(defun metadata-key (hash key)
  "Return the database key to retrieve metadata KEY associted with blob
of HASH."
  (concatenate '(vector (unsigned-byte 8))
	       hash
	       (string-to-utf-8-bytes (concat ":" key))))

(defun write-bytevector-with-length (bv stream)
  "Write length of BV followed by BV itself to STREAM. The length is
written as a little endian 64-bit unsigned integer."
  (write-sequence (uint64-to-octets (length bv)) stream)
  (map (type-of bv)
       (lambda (el)
	 (cond
	   ((integerp el) (write-byte el stream))
	   ((stringp el) (write-utf-8-bytes el stream))
	   ((floatp el)
	    (write-utf-8-bytes
	     (write-to-string el) stream))))
       bv))

(defun hash-vector-length (hash-vector)
  "Return the number of hashes in HASH-VECTOR."
  (/ (length hash-vector)
     (digest-length *blob-hash-digest*)))


(defun bv-hash (bv &optional metadata)
  "Return the hash of a bytevector BV and optionally write a HEADER to
the hash stream"
  (with-digesting-stream (stream *blob-hash-digest*)
    ;; Write bytevector
    (write-bytevector-with-length bv stream)
    ;; Write metadata
    (mapc (lambda-match
	    ((cons key value)
	     (write-bytevector-with-length (string-to-utf-8-bytes key)
					   stream)
	     (write-bytevector-with-length
	      (etypecase value
		(string (string-to-utf-8-bytes value))
		((unsigned-byte 64) (uint64-to-octets value))
		((vector (unsigned-byte 8)) value))
	      stream)))
	  metadata)))

(defun hash-vector-ref (hash-vector n)
  "Return the Nth hash in HASH-VECTOR."
  (let ((hash-length (digest-length *blob-hash-digest*)))
    (make-array hash-length
		:element-type '(unsigned-byte 8)
		:displaced-to hash-vector
		:displaced-index-offset (* n hash-length))))


;; Matrix Data Structures and associated helper functions

(defstruct sampledata matrix metadata)

(defstruct sampledata-db-matrix
  db hash nrows ncols row-pointers column-pointers array transpose)

(defun matrix-row (matrix n)
  "Return the Nth row of MATRIX."
  (let ((ncols (array-dimension matrix 1)))
    (make-array ncols
		:element-type (array-element-type matrix)
		:displaced-to matrix
		:displaced-index-offset (* n ncols))))

(defun matrix-column (matrix n)
  "Return the Nth column of MATRIX."
  (let ((column (make-array (array-dimension matrix 0))))
    (dotimes (i (length column))
      (setf (aref column i)
	    (aref matrix i n)))
    column))


;; Working with sample data matrixes

(defun sampledata-db-get (db key)
  "Get bytevector with KEY from sampledata DB.  KEY may be a hash or a
string.  If it is a string, it is encoded into octets before querying
the database."
  (g3t db (if (stringp key)
	      (string-to-utf-8-bytes key)
	      key)))

(defun sampledata-db-put (db bv &optional metadata)
  "Put BV - a bytevector - into DB.  Associate HEADER, representing the
name of the columns, with BV.  Return the hash."
  (let ((hash (bv-hash bv metadata)))
    (unless (sampledata-db-get db hash)
      (put db hash bv)
      (mapc (lambda-match
	      ((cons key value)
	       (put db (metadata-key hash key) value)))
	    metadata))
    hash))

(defun sampledata-db-metadata-get (db hash key)
  "Get metadata associated with KEY, HASH from sampledata DB."
  (sampledata-db-get db (metadata-key hash key)))

(defun sampledata-db-current-matrix-hash (db)
  "Return the hash of the current matrix in the sampledata matrix DB."
  (hash-vector-ref (sampledata-db-get db "versions")
		   0))

(defun sampledata-db-matrix (db hash)
  "Return the matrix identified by HASH from sampledata matrix DB."
  (let ((nrows (octets-to-uint64
		(sampledata-db-metadata-get db hash "nrows")))
	(ncols (octets-to-uint64
		(sampledata-db-metadata-get db hash "ncols")))
	(hash-length (digest-length *blob-hash-digest*)))
    (make-sampledata-db-matrix
     :db db
     :hash hash
     :nrows nrows
     :ncols ncols
     :row-pointers (make-array (* nrows hash-length)
			       :element-type '(unsigned-byte 8)
			       :displaced-to (sampledata-db-get db hash))
     :column-pointers (make-array (* ncols hash-length)
				  :element-type '(unsigned-byte 8)
				  :displaced-to (sampledata-db-get db hash)
				  :displaced-index-offset (* nrows
							     hash-length)))))

(defun sampledata-db-matrix-put (db matrix)
  "Put sampledata MATRIX into DB and return the hash"
  (let ((matrix (sampledata-matrix matrix)))
    (match (array-dimensions matrix)
      ((list nrows ncols)
       (sampledata-db-put
	db
	(with-octet-output-stream (stream)
	  (dotimes (i nrows)
	    (write-sequence (sampledata-db-put db (matrix-row matrix i))
			    stream))
	  (dotimes (j ncols)
	    (write-sequence (sampledata-db-put db (matrix-column matrix j))
			    stream)))
	`(("nrows" . ,nrows)
	  ("ncols" . ,ncols)))))))

(defun (setf sampledata-db-current-matrix-hash) (hash db)
  "Set HASH as the current matrix in the sampledata matrix DB."
  ;; Prepend hash into versions array.
  (put db (string-to-utf-8-bytes "versions")
       (concatenate '(vector (unsigned-byte 8))
		    hash
		    (sampledata-db-get db "versions")))
  ;; Write a read-optimized copy of the current matrix into the database
  (let ((matrix (sampledata-db-matrix db hash)))
    (put db
	 (string-to-utf-8-bytes "current")
	 (sampledata-db-put
	  db
	  (with-octet-output-stream (stream)
	    (dotimes (i (sampledata-db-matrix-nrows matrix))
	      (write-sequence (sampledata-db-matrix-row-ref matrix i)
			      stream))
	    (dotimes (i (sampledata-db-matrix-ncols matrix))
	      (write-sequence (sampledata-db-matrix-column-ref matrix i)
			      stream)))
	  `(("matrix" . ,hash))))))

(defun sampledata-db-current-matrix (db)
  "Return the latest version of the matrix in DB."
  (let* ((read-optimized-blob (sampledata-db-get db (sampledata-db-get db "current")))
	 (current-matrix-hash (sampledata-db-current-matrix-hash db))
	 (nrows (octets-to-uint64
		 (sampledata-db-metadata-get db current-matrix-hash "nrows")))
	 (ncols (octets-to-uint64
		 (sampledata-db-metadata-get db current-matrix-hash "ncols"))))
    (make-sampledata-db-matrix
     :db db
     :nrows nrows
     :ncols ncols
     :array (make-array (list nrows ncols)
			:element-type '(unsigned-byte 8)
			:displaced-to read-optimized-blob)
     :transpose (make-array (list ncols nrows)
			    :element-type '(unsigned-byte 8)
			    :displaced-to read-optimized-blob))))

(defun sampledata-db-current-matrix-ref (matrix)
  "Return MATRIX as a 2-D array."
  (let ((array (sampledata-db-matrix-array matrix)))
    (if array
	array
	(let* ((nrows (sampledata-db-matrix-nrows matrix))
	       (ncols (sampledata-db-matrix-ncols matrix))
	       (array (make-array (list nrows ncols)
				  :element-type '(unsigned-byte 8))))
	  (dotimes (i nrows)
	    (let ((row (sampledata-db-matrix-row-ref matrix i)))
	      (dotimes (j ncols)
		(setf (aref array i j)
		      (aref row j)))))
	  array))))

(defun sampledata-db-matrix-row-ref (matrix i)
  "Return the Ith row of sampledata db MATRIX."
  (let ((db (sampledata-db-matrix-db matrix))
	(array (sampledata-db-matrix-array matrix)))
    (if array
	(matrix-row array i)
	(sampledata-db-get
	 db
	 (hash-vector-ref (sampledata-db-matrix-row-pointers matrix) i)))))

(defun sampledata-db-matrix-column-ref (matrix j)
  "Return the Jth row of sampledata db MATRIX."
  (let ((db (sampledata-db-matrix-db matrix))
	(transpose (sampledata-db-matrix-array matrix)))
    (if transpose
	(matrix-row transpose j)
	(sampledata-db-get
	 db
	 (hash-vector-ref (sampledata-db-matrix-column-pointers matrix) j)))))

(defun collect-garbage (db)
  "Delete all keys in DB that are not associated with a live hash."
  (with-cursor (cursor db)
    (cursor-first cursor)
    (do-cursor (key value cursor)
      (unless (live-key-p db key)
        (cursor-del cursor)))))


(defun hash-in-hash-vector-p (hash hash-vector)
  "Return non-nil if HASH is in HASH-VECTOR. Else, return nil."
  (find-index (lambda (i)
                (equalp (hash-vector-ref hash-vector i)
                        hash))
              (hash-vector-length hash-vector)))

(defun live-key-p (db key)
  "Return non-nil if KEY is live. Else, return nil."
  (or (equalp key (string-to-utf-8-bytes "current"))
      (equalp key (string-to-utf-8-bytes "versions"))
      (equalp key (sampledata-db-get db "current"))
      (let ((versions-hash-vector (sampledata-db-get db "versions"))
            (key-hash-prefix (make-array (digest-length *blob-hash-digest*)
                                         :element-type '(unsigned-byte 8)
                                         :displaced-to key)))
        (or (hash-in-hash-vector-p key-hash-prefix versions-hash-vector)
            (find-index (lambda (i)
                          (hash-in-hash-vector-p
                           key-hash-prefix
                           (sampledata-db-get db (hash-vector-ref versions-hash-vector i))))
                        (hash-vector-length versions-hash-vector))))))

(defun import-into-sampledata-db (sampledata sampledata-database)
  "Import SAMPLEDATA which is a sampledata-matrix object into
SAMPLEDATA-DATABASE."
  (with-sampledata-db (db sampledata-database :write t)
    (let* ((hash (sampledata-db-matrix-put db sampledata))
	   (db-matrix (sampledata-db-matrix db hash)))
      ;; Read written data back and verify.
      (unless (and (all (lambda (i)
			  (equalp (matrix-row (sampledata-matrix sampledata) i)
				  (sampledata-db-matrix-row-ref db-matrix i)))
			(iota (sampledata-db-matrix-nrows db-matrix)))
		   (all (lambda (i)
			  (equalp (matrix-column (sampledata-matrix sampledata) i)
				  (sampledata-db-matrix-column-ref db-matrix i)))
			(iota (sampledata-db-matrix-ncols db-matrix))))
	;; Roll back database updates.
	(collect-garbage db)
	;; Exit with error message.
	(format *error-output*
		"Rereading and verifying sampledata matrix written to \"~a\" failed.
This is a bug. Please report it.
"
		sampledata-database)
	(uiop:quit 1))
      ;; Set the current matrix.
      (setf (sampledata-db-current-matrix-hash db)
	    hash))))


;; Dumping an Retriewing Data Examples

(import-into-sampledata-db
 (make-sampledata
  :matrix (make-array '(2 3)
		      :initial-contents '((1 10 1) (1 0 1)))
  :metadata '(("header" . "Value, Count, SE")))
 "/tmp/test-sampledata/")

;; Get current database
(with-sampledata-db (db "/tmp/test-sampledata/" :write t)
  (sampledata-db-current-matrix db))
